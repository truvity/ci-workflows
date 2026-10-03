#!/usr/bin/env bash
# Cases for auto-release.yaml: the release gate, then the tagging step with
# its CHANGELOG heading. Each block is lifted out of BOTH tag jobs (between
# the `>>> gate` / `<<< gate` and `>>> tag` / `<<< tag` markers), checked
# identical, and run against a stubbed `gh` for each case. The tagging
# cases also run against a real git repository and a real bare "origin", so
# what they assert is what the tag points at, not what a script said.
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

# ── The tagging step and its CHANGELOG heading ──────────────────────────
extract_tag() { # $1 = 1|2, the nth tag block
  awk -v n="$1" '/# >>> tag/{c++} c==n && /# >>> tag/{on=1} on{print} /# <<< tag/{if(c==n)on=0}' "$wf" | sed 's/^          //'
}
extract_tag 1 > "$work/tag1.sh"
extract_tag 2 > "$work/tag2.sh"
[ -s "$work/tag1.sh" ] || { echo "no tag block found"; exit 1; }
diff -u "$work/tag1.sh" "$work/tag2.sh" || { echo "the two jobs' tag blocks differ"; exit 1; }
bash -n "$work/tag1.sh"

mkdir "$work/bin2"
cat > "$work/bin2/merge-now" <<'STUB'
#!/usr/bin/env bash
# What GitHub does when the checks go green: fast-forward master to the
# heading branch (a one-commit rebase merge on an unmoved master is that).
branch=$(git --git-dir="$ORIGIN" for-each-ref --format='%(refname)' 'refs/heads/auto-release/')
sha=$(git --git-dir="$ORIGIN" rev-parse "$branch")
git --git-dir="$ORIGIN" update-ref refs/heads/master "$sha"
echo MERGED > "$S/state"; echo "$sha" > "$S/merge_sha"
STUB
cat > "$work/bin2/gh" <<'STUB'
#!/usr/bin/env bash
# The handful of gh calls the tagging step makes, answered from $S.
echo "$*" >> "$S/calls"
case "$1 $2" in
  "pr list")
    case "$*" in
      *--head*) cat "$S/own_pr" 2>/dev/null || true ;;
      *)        cat "$S/human" 2>/dev/null || echo 0 ;;
    esac ;;
  "pr create")
    while [ $# -gt 0 ]; do [ "$1" = --title ] && echo "$2" > "$S/title"; shift; done
    echo 7 > "$S/own_pr"; echo OPEN > "$S/state"
    echo "https://github.com/o/r/pull/7" ;;
  "pr merge")
    [ -e "$S/never" ] || "$(dirname "$0")/merge-now" ;;
  "pr view")
    case "$*" in
      *mergeCommit*) cat "$S/merge_sha" ;;
      *)             cat "$S/state" ;;
    esac ;;
  "api repos/o/r") echo rebase ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
STUB
cat > "$work/bin2/devbox" <<'STUB'
#!/usr/bin/env bash
# `devbox run -- <cmd...>`: the command itself, with the environment as is.
echo "devbox $*" >> "$S/devbox_calls"
[ "$1" = run ] && [ "$2" = -- ] || { echo "unexpected devbox call: $*" >&2; exit 1; }
shift 2
exec "$@"
STUB
chmod +x "$work/bin2/gh" "$work/bin2/merge-now" "$work/bin2/devbox"

# fixture <changelog> <tag>... : a bare origin and a clone whose master has
# moved one commit past the tags. The changelog is the one at HEAD.
fixture() {
  local cl="$1"; shift
  rm -rf "$work/o.git" "$work/w" "$work/s"; mkdir "$work/s"
  export ORIGIN="$work/o.git" S="$work/s"
  git init -q --bare -b master "$ORIGIN"
  git init -q -b master "$work/w"
  ( cd "$work/w"
    git config user.name fixture; git config user.email fixture@example.com
    git remote add origin "$ORIGIN"
    printf '%s\n' "$cl" > CHANGELOG.md; echo 1 > dep; git add .; git commit -q -m init
    for t in "$@"; do git tag -a "$t" -m "$t"; done
    echo 2 > dep; git commit -q -am "chore(deps): bump"
    git push -q origin master --tags )
}
run_tag() { # env overrides as arguments, e.g. HEADING_MODE=never
  : > "$work/sum"; local rc=0
  ( cd "$work/w" && env PREFIX=v BOT=bot GH_TOKEN=x REPO=o/r BASE=master \
      WAIT_MINUTES=0 POLL_SECONDS=0 GITHUB_STEP_SUMMARY="$work/sum" \
      PATH="$work/bin2:$PATH" "$@" bash "$work/tag1.sh" >"$work/log" 2>&1 ) || rc=$?
  return "$rc"
}
o() { git --git-dir="$ORIGIN" "$@"; }
# the file as the tagged commit has it
at() { o show "$1^{commit}:CHANGELOG.md"; }
ok() { # <name> <condition...>
  local name="$1"; shift
  if "$@"; then echo "ok    $name"; else echo "FAIL  $name"; fail=1; sed 's/^/        | /' "$work/log" 2>/dev/null | tail -5; fi
}
no_tag() { ! o rev-parse -q --verify "refs/tags/$1" >/dev/null; }
tag_on_master() { [ "$(o rev-parse "$1^{commit}")" = "$(o rev-parse master)" ]; }
no_pr() { [ ! -e "$S/title" ]; }
has() { grep -qxF -- "$2" <<<"$1"; }

UNREL=$'# Changelog\n\n## Unreleased\n\n- Something a consumer sees.\n\n## v1.2.0\n\n- First.'
case_name="unreleased with entries -> renamed, committed, tag names the merged commit"
fixture "$UNREL" v1.2.0
rc=0; run_tag || rc=$?
ok "$case_name" test "$rc" = 0
ok "  the tag names master's tip, which carries the heading" tag_on_master v1.2.1
ok "  heading is ## v1.2.1, Unreleased is gone" bash -c 'h=$(git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md); grep -qx "## v1.2.1" <<<"$h" && ! grep -q "## Unreleased" <<<"$h" && grep -qx -- "- Something a consumer sees." <<<"$h"' "$ORIGIN"
ok "  the PR carries the conventional title" grep -qxF "docs(changelog): heading for the v1.2.1 release" "$S/title"
ok "  no date, because the headings carry none" bash -c '! git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -q "^## v1.2.1 "' "$ORIGIN"
ok "  armed with the repository's merge method" grep -q '^pr merge 7 --repo o/r --auto --rebase$' "$S/calls"

fixture $'# Changelog\n\n## Unreleased\n\n- Entry.\n\n## v1.2.0 — 2026-09-01\n\n- First.' v1.2.0
rc=0; run_tag || rc=$?
ok "dated headings -> the new one is dated (UTC today)" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "## v1.2.1 — $(date -u +%F)"' "$ORIGIN"

fixture $'# Changelog\n\n## Unreleased\n\n### Contracts\n\n- Entry.\n\n## v1.2.0\n\n- First.' v1.2.0
rc=0; run_tag || rc=$?
ok "sub-headings under Unreleased move with it" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "### Contracts"' "$ORIGIN"

# Dependency-only: nothing under Unreleased.
DEPS=$'# Changelog\n\n## Unreleased\n\n## v1.2.3\n\n- A patch with its own heading.\n\n## v1.2.0\n\n- First.'
fixture "$DEPS" v1.2.0 v1.2.3
rc=0; run_tag || rc=$?
ok "empty Unreleased, newest patch has a heading -> Dependency updates heading" test "$rc" = 0
ok "  heading sits under Unreleased, above v1.2.3, with the bullet" bash -c 'h=$(git --git-dir="$0" show v1.2.4^{commit}:CHANGELOG.md | grep -E "^(## |- )" | paste -sd"|"); [ "$h" = "## Unreleased|## v1.2.4|- Dependency updates.|## v1.2.3|- A patch with its own heading.|## v1.2.0|- First." ]' "$ORIGIN"

NOPATCH=$'# Changelog\n\n## Unreleased\n\n## v1.2.0\n\n- First.'
fixture "$NOPATCH" v1.2.0
rc=0; run_tag || rc=$?
ok "empty Unreleased, no patch heading convention -> tags HEAD, no PR (C5 exempts it)" test "$rc" = 0
ok "  tag is on master, file untouched" tag_on_master v1.2.1
ok "  no PR was opened" no_pr
ok "  changelog byte-identical" bash -c '[ "$(git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md)" = "$1" ]' "$ORIGIN" "$NOPATCH"

fixture "$NOPATCH" v1.2.0
rc=0; run_tag HEADING_MODE=always || rc=$?
ok "always -> the Dependency updates heading even with no convention" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx -- "- Dependency updates."' "$ORIGIN"

fixture $'# Changelog\n\n## v1.2.3\n\n- Patch.\n\n## v1.2.0\n\n- First.' v1.2.0 v1.2.3
rc=0; run_tag || rc=$?
ok "no Unreleased at all, patch convention -> heading placed above the newest version" bash -c 'git --git-dir="$0" show v1.2.4^{commit}:CHANGELOG.md | grep -E "^## " | head -1 | grep -qx "## v1.2.4"' "$ORIGIN"

# Opting out and the other shapes that keep today's behaviour.
fixture "$UNREL" v1.2.0
rc=0; run_tag HEADING_MODE=never || rc=$?
ok "never -> old behaviour: tag on HEAD, file untouched, no PR" test "$rc" = 0
ok "  tag is on master" tag_on_master v1.2.1
ok "  no PR was opened" no_pr
ok "  Unreleased still there" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "## Unreleased"' "$ORIGIN"

fixture "$UNREL"; rm -f "$work/w/CHANGELOG.md"; ( cd "$work/w" && git rm -q CHANGELOG.md && git commit -q -m nochangelog && git push -q origin master ) 2>/dev/null
( cd "$work/w" && git tag -a v1.2.0 "$(git rev-list --max-parents=0 HEAD)" -m x && git push -q origin v1.2.0 )
rc=0; run_tag || rc=$?
ok "no CHANGELOG file -> tags HEAD, no PR" test "$rc" = 0
ok "  tag is on master" tag_on_master v1.2.1
ok "  no PR was opened" no_pr

fixture $'# Changelog\n\n## v1.2.0\n\n- First.\n\n## Unreleased\n\n- Misplaced.' v1.2.0
rc=0; run_tag || rc=$?
ok "Unreleased not first -> warns, tags HEAD, rewrites nothing" test "$rc" = 0
ok "  warned" grep -q '^::warning::' "$work/log"
ok "  no PR was opened" no_pr
ok "  tag is on master" tag_on_master v1.2.1

# Never rewrite, idempotent, nothing to do.
fixture $'# Changelog\n\n## Unreleased\n\n- Entry.\n\n## v1.2.1\n\n- Already written by hand.\n\n## v1.2.0\n\n- First.' v1.2.0
rc=0; run_tag || rc=$?
ok "heading for the next version already exists -> not rewritten, no PR, tag on HEAD" test "$rc" = 0
ok "  no PR was opened" no_pr
ok "  tag is on master" tag_on_master v1.2.1
ok "  Unreleased untouched" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "## Unreleased"' "$ORIGIN"

fixture "$UNREL" v1.2.0
( cd "$work/w" && git tag -a v1.2.1 -m x && git push -q origin v1.2.1 )
rc=0; run_tag || rc=$?
ok "master already at the latest tag -> nothing released" test "$rc" = 0
ok "  no PR was opened" no_pr
ok "  no v1.2.2" no_tag v1.2.2

fixture "$UNREL"
rc=0; run_tag || rc=$?
ok "no tags yet -> a human cuts the first" test "$rc" = 0
ok "  no PR was opened" no_pr

# Concurrency with a person's release PR.
fixture "$UNREL" v1.2.0
echo 1 > "$S/human"
rc=0; run_tag || rc=$?
ok "a minor's heading PR is open -> stands aside: no tag, no PR" test "$rc" = 0
ok "  no v1.2.1" no_tag v1.2.1
ok "  no PR was opened" no_pr
ok "  said so in the summary" grep -q 'leaving v1.2.1 to it' "$work/sum"
ok "  the title test: matches a minor, not a patch or v1.2.10" bash -c '
  t=$(grep -o "test(\"[^\"]*\")" "$0" | head -1 | sed "s/^test(\"//; s/\")$//; s/\\\\\\\\/\\\\/g")
  jq -en --arg re "$t" "[\"docs(changelog): heading for the v1.3.0 release\", \"docs(changelog): heading for the v2.0.0 release\"] | all(test(\$re))" >/dev/null &&
  jq -en --arg re "$t" "[\"docs(changelog): heading for the v1.2.1 release\", \"docs(changelog): heading for the v1.2.10 release\", \"feat: heading for the v1.3.0 release\"] | any(test(\$re)) | not" >/dev/null' "$work/tag1.sh"

# Failure paths: no tag, PR left, and the next run resumes it.
fixture "$UNREL" v1.2.0
touch "$S/never"
rc=0; run_tag || rc=$?
ok "heading PR never merges -> run fails red" test "$rc" != 0
ok "  no tag was cut" no_tag v1.2.1
ok "  the error says what to expect" grep -q 'did not merge within' "$work/log"
rm -f "$S/never"; "$work/bin2/merge-now"
( cd "$work/w" && git checkout -q master )
rc=0; run_tag || rc=$?
ok "next run resumes the open PR (merged meanwhile) and tags its commit" test "$rc" = 0
ok "  one PR only" bash -c '[ "$(grep -c "^pr create" "$0")" = 1 ]' "$S/calls"
ok "  tag is on master with the heading" tag_on_master v1.2.1
ok "  heading is in the tagged file" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "## v1.2.1"' "$ORIGIN"

fixture "$UNREL" v1.2.0
touch "$S/never"; run_tag || true; rm -f "$S/never"
echo CLOSED > "$S/state"
( cd "$work/w" && git checkout -q master )   # a real run starts from a fresh checkout
rc=0; run_tag || rc=$?
ok "heading PR closed unmerged -> run fails red, no tag" test "$rc" != 0
ok "  no v1.2.1" no_tag v1.2.1

# ── version-bump-command ────────────────────────────────────────────────
no_devbox() { [ ! -e "$S/devbox_calls" ]; }
tagged() { o show "$1^{commit}:$2"; }
BUMP='printf "%s\n" "$VERSION" > ver; printf "%s\n" "$TAG" > tagname'

fixture "$UNREL" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND="$BUMP" || rc=$?
ok "bump set -> run succeeds, tag on master" test "$rc" = 0
ok "  tag is on master" tag_on_master v1.2.1
ok "  VERSION is X.Y.Z without the prefix" bash -c '[ "$(git --git-dir="$0" show v1.2.1^{commit}:ver)" = 1.2.1 ]' "$ORIGIN"
ok "  TAG is the tag" bash -c '[ "$(git --git-dir="$0" show v1.2.1^{commit}:tagname)" = v1.2.1 ]' "$ORIGIN"
ok "  the heading is in the same tagged commit" bash -c 'git --git-dir="$0" show v1.2.1^{commit}:CHANGELOG.md | grep -qx "## v1.2.1"' "$ORIGIN"
ok "  one heading commit carries both files" bash -c 'g="git --git-dir=$0"; [ "$($g rev-list --count v1.2.0..v1.2.1)" = 2 ] && [ "$($g diff --name-only v1.2.1~1 v1.2.1 | sort | paste -sd,)" = CHANGELOG.md,tagname,ver ]' "$ORIGIN"
ok "  ran once, inside devbox" bash -c '[ "$(wc -l < "$0")" = 1 ]' "$S/devbox_calls"
ok "  one PR" bash -c '[ "$(grep -c "^pr create" "$0")" = 1 ]' "$S/calls"

fixture "$UNREL" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND=true || rc=$?
ok "a bump that changes nothing -> fails loudly" test "$rc" != 0
ok "  says so" grep -q 'changed nothing' "$work/log"
ok "  no PR was opened" no_pr
ok "  no tag" no_tag v1.2.1
ok "  nothing pushed to the heading branch" bash -c '[ -z "$(git --git-dir="$0" for-each-ref refs/heads/auto-release/)" ]' "$ORIGIN"

fixture "$UNREL" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND='false' || rc=$?
ok "a bump that fails -> fails, no PR, no tag" test "$rc" != 0
ok "  no PR was opened" no_pr
ok "  no tag" no_tag v1.2.1

fixture "$UNREL" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND= || rc=$?
ok "empty bump -> unchanged behaviour, heading PR as before" test "$rc" = 0
ok "  devbox never called" no_devbox
ok "  the heading commit holds the changelog only" bash -c 'g="git --git-dir=$0"; [ "$($g diff --name-only v1.2.1~1 v1.2.1)" = CHANGELOG.md ]' "$ORIGIN"
ok "  the commit message is the unchanged one" bash -c '[ "$(git --git-dir="$0" log -1 --format=%b v1.2.1^{commit} | head -1)" = "Written by the shared auto-release workflow so that the tag names the commit that carries its own heading." ]' "$ORIGIN"

fixture "$UNREL" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND="$BUMP" HEADING_MODE=never || rc=$?
ok "bump with changelog-heading: never -> refused" test "$rc" != 0
ok "  the error names the combination" grep -q 'cannot be combined with changelog-heading: never' "$work/log"
ok "  no PR was opened" no_pr
ok "  no tag" no_tag v1.2.1
ok "  devbox never called" no_devbox

# Resume: the open PR is trusted, the bump does not run again.
fixture "$UNREL" v1.2.0
touch "$S/never"
rc=0; run_tag VERSION_BUMP_COMMAND='echo bumped >> bump.log' || rc=$?
ok "bump, heading PR never merges -> red" test "$rc" != 0
rm -f "$S/never"; "$work/bin2/merge-now"
( cd "$work/w" && git checkout -q master )
rc=0; run_tag VERSION_BUMP_COMMAND='echo bumped >> bump.log' || rc=$?
ok "resumed open PR -> tagged, not re-bumped" test "$rc" = 0
ok "  devbox ran once across both runs" bash -c '[ "$(wc -l < "$0")" = 1 ]' "$S/devbox_calls"
ok "  one PR only" bash -c '[ "$(grep -c "^pr create" "$0")" = 1 ]' "$S/calls"
ok "  the tagged commit has the bump exactly once" bash -c '[ "$(git --git-dir="$0" show v1.2.1^{commit}:bump.log)" = bumped ]' "$ORIGIN"

# A heading a person wrote: the bump is theirs, nothing runs.
fixture $'# Changelog\n\n## Unreleased\n\n- Entry.\n\n## v1.2.1\n\n- By hand.\n\n## v1.2.0\n\n- First.' v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND="$BUMP" || rc=$?
ok "heading already there -> bump skipped, tagged as it stands" test "$rc" = 0
ok "  devbox never called" no_devbox
ok "  no PR was opened" no_pr
ok "  tag is on master" tag_on_master v1.2.1
ok "  said so in the summary" grep -q 'version-bump-command skipped' "$work/sum"

# Dependency-only patch: the bump needs a PR, so one is opened regardless of convention.
fixture "$NOPATCH" v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND="$BUMP" || rc=$?
ok "bump with an empty Unreleased and no heading convention -> heading PR carries the bump" test "$rc" = 0
ok "  heading and bump are in the tagged commit" bash -c 'g="git --git-dir=$0"; $g show v1.2.1^{commit}:CHANGELOG.md | grep -qx -- "- Dependency updates." && [ "$($g show v1.2.1^{commit}:ver)" = 1.2.1 ]' "$ORIGIN"

# A misplaced Unreleased leaves no PR to carry the bump: refuse, do not tag stale files.
fixture $'# Changelog\n\n## v1.2.0\n\n- First.\n\n## Unreleased\n\n- Misplaced.' v1.2.0
rc=0; run_tag VERSION_BUMP_COMMAND="$BUMP" || rc=$?
ok "bump with no PR possible -> refused, no tag" test "$rc" != 0
ok "  no tag" no_tag v1.2.1

# The workflow wires the bump to devbox only when the input is set, in both jobs.
ok "setup-devbox only with the input, in both jobs" bash -c '[ "$(grep -c "inputs.version-bump-command != ..$" "$0")" = 2 ]' "$wf"
ok "the bump reaches the shell through env only" bash -c 'grep -c "VERSION_BUMP_COMMAND: \${{ inputs.version-bump-command }}" "$0" | grep -qx 2' "$wf"

# The workflow wires the opt-out to the permission it asks the issuer for.
ok "changelog-heading: never keeps pull_requests:read" \
  grep -q "inputs.changelog-heading == 'never' && 'contents:write,pull_requests:read' || 'contents:write,pull_requests:write'" "$wf"
ok "no \${{ }} inside any run: of the tag blocks" bash -c '! grep -q "\${{" "$0" "$1"' "$work/tag1.sh" "$work/tag2.sh"

[ "$fail" = 0 ] && echo "auto-release cases pass"
exit "$fail"
