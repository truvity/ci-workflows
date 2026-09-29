#!/usr/bin/env bash
# Cases for auto-release.yaml's release gate. The gate block is lifted out
# of BOTH tag jobs (between the `>>> gate` / `<<< gate` markers), checked
# identical, and run against a stubbed `gh` for each case.
#
#   hack/auto-release-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/auto-release.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract() { # $1 = 1|2, the nth gate block
  awk -v n="$1" '/# >>> gate/{c++} c==n && /# >>> gate/{on=1} on{print} /# <<< gate/{if(c==n)on=0}' "$wf" | sed 's/^          //'
}
extract 1 > "$work/gate1.sh"
extract 2 > "$work/gate2.sh"
[ -s "$work/gate1.sh" ] || { echo "no gate block found"; exit 1; }
diff -u "$work/gate1.sh" "$work/gate2.sh" || { echo "the two jobs' gate blocks differ"; exit 1; }

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# gh api <path> [--paginate] [--jq expr], answered from FAKE_* env.
path="$2"; expr=""
while [ $# -gt 0 ]; do [ "$1" = --jq ] && expr="$2"; shift; done
case "$path" in
  */commits/*/pulls) data="$FAKE_PULLS" ;;
  */pulls/*/commits) data="$FAKE_PR_COMMITS" ;;
  */commits/*)       data="$FAKE_HEAD" ;;
  *) echo "unexpected gh path $path" >&2; exit 1 ;;
esac
if [ -n "$expr" ]; then jq -r "$expr" <<<"$data"; else printf '%s\n' "$data"; fi
STUB
chmod +x "$work/bin/gh"

fail=0
# case <name> <want: release|batch> <pulls-json> [pr-commit-subjects-json] [head-json]
case_() {
  local name="$1" want="$2"
  export FAKE_PULLS="$3" FAKE_PR_COMMITS="${4:-[]}" FAKE_HEAD="${5:-{\}}"
  : > "$work/out"; : > "$work/sum"
  GH_TOKEN=x REPO=o/r SHA=abc GITHUB_OUTPUT="$work/out" GITHUB_STEP_SUMMARY="$work/sum" \
    PATH="$work/bin:$PATH" bash "$work/gate1.sh"
  local got=release
  grep -q '^skip=true$' "$work/out" && got=batch
  if [ "$got" = "$want" ]; then echo "ok    $name -> $got"; else echo "FAIL  $name: want $want, got $got"; fail=1; fi
}
# pr <title> <login> <type> <labels,comma>
pr() {
  jq -nc --arg t "$1" --arg l "$2" --arg ty "$3" --arg lb "$4" \
    '[{number: 7, title: $t, user: {login: $l, type: $ty}, labels: ($lb | split(",") | map(select(. != "") | {name: .}))}]'
}
subjects() { jq -nc '$ARGS.positional | map({commit: {message: .}})' --args "$@"; }
H=alice; U=User; R='renovate[bot]'; B=Bot

case_ "human fix releases"                      release "$(pr 'fix: handle nil' $H $U '')"
case_ "human fix with scope releases"           release "$(pr 'fix(api): handle nil' $H $U '')"
case_ "human fix! releases (still one patch)"   release "$(pr 'fix!: drop old flag' $H $U '')"
case_ "human fix(scope)! releases"              release "$(pr 'fix(api)!: drop old flag' $H $U '')"
case_ "renovate fix(deps) batches"              batch   "$(pr 'fix(deps): update module x' $R $B 'dependencies')"
case_ "renovate fix by label only batches"      batch   "$(pr 'fix: bump y' alice $U 'dependencies')"
case_ "feat batches"                            batch   "$(pr 'feat: add flag' $H $U '')"
case_ "chore batches"                           batch   "$(pr 'chore: tidy' $H $U '')"
case_ "docs batches"                            batch   "$(pr 'docs: reword' $H $U '')"
case_ "security label releases"                 release "$(pr 'chore(deps): bump z' $R $B 'dependencies,security')"
case_ "security label on a feat releases"       release "$(pr 'feat: x' $H $U 'security')"
case_ "revert of a fix batches"                 batch   "$(pr 'Revert "fix: handle nil"' $H $U '')" "$(subjects 'Revert "fix: handle nil"')"
case_ "revert: type batches"                    batch   "$(pr 'revert: fix: handle nil' $H $U '')"
case_ "rebase merge, untitled-type PR, one fix commit releases" release \
  "$(pr 'Tidy up the parser' $H $U '')" "$(subjects 'chore: rename' 'fix(parser): off by one' 'docs: note')"
case_ "rebase merge, untitled-type PR, no fix commit batches" batch \
  "$(pr 'Tidy up the parser' $H $U '')" "$(subjects 'chore: rename' 'feat: add' 'docs: note')"
case_ "fix title over feat commits releases (title wins)" release \
  "$(pr 'fix: handle nil' $H $U '')" "$(subjects 'feat: add')"
case_ "feat title over a fix commit batches (title wins)" batch \
  "$(pr 'feat: add flag' $H $U '')" "$(subjects 'fix: typo')"
case_ "renovate PR with unconventional title and fix commit batches" batch \
  "$(pr 'Update dependency x' $R $B 'dependencies')" "$(subjects 'fix(deps): update x')"
case_ "direct push of a human fix releases"     release '[]' '[]' '{"commit":{"message":"fix: hot\n\nbody"},"author":{"login":"alice","type":"User"}}'
case_ "direct push of a renovate fix batches"   batch   '[]' '[]' '{"commit":{"message":"fix(deps): x"},"author":{"login":"renovate[bot]","type":"Bot"}}'
case_ "direct push of a chore batches"          batch   '[]' '[]' '{"commit":{"message":"chore: x"},"author":{"login":"alice","type":"User"}}'

[ "$fail" = 0 ] && echo "auto-release cases pass"
exit "$fail"
