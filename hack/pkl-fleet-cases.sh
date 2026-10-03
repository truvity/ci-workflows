#!/usr/bin/env bash
# Cases for pkl-fleet.yaml: resolving the target version, finding the
# consumers that need a bump, rewriting the dependency URIs (every form
# `PklProject` and `PklProject.deps.json` use, several projects, a no-op,
# classification, refusals), the resolve/generate step, and the pull-request
# step against a real git remote and a stubbed API. Each block between the
# `>>> name` and `<<< name` markers is lifted out of the workflow and run as
# written, so what is asserted is what a fleet run executes.
#
#   hack/pkl-fleet-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/pkl-fleet.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

block() {
  awk -v n="$1" '$0 ~ "# >>> " n " "{on=1} on{print} $0 ~ "# <<< " n{on=0}' "$wf" | sed 's/^          //' > "$work/$1.sh"
  [ -s "$work/$1.sh" ] || { echo "no $1 block found"; exit 1; }
}
for b in target consumers rewrite resolve publish; do block "$b"; done

fail=0
pass() { echo "ok    $1"; }
nope() { echo "FAIL  $1"; fail=1; }

# ── stubs ────────────────────────────────────────────────────────────────
mkdir "$work/bin"
# A GitHub API in files: $FAKE/<METHOD><path with every odd character as _>.
# A missing GET is a 404 (curl -f exits 22); a missing write answers {}.
cat > "$work/bin/curl" <<'STUB'
#!/usr/bin/env bash
method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -d) data="$2"; shift 2 ;;
    -H|--max-time) shift 2 ;;
    -f*|-s*) shift ;;
    *) url="$1"; shift ;;
  esac
done
[ "$data" = "@-" ] && data=$(cat)
path=${url#https://api.test}
echo "$method $path $data" >> "$FAKE/calls"
key=$(printf '%s' "$method$path" | tr -c 'A-Za-z0-9.\n-' '_')
if [ -f "$FAKE/$key" ]; then cat "$FAKE/$key"; exit 0; fi
if [ "$method" = GET ]; then exit 22; fi
echo '{}'
STUB
cat > "$work/bin/devbox" <<'STUB'
#!/usr/bin/env bash
[ "$1 $2" = "run --" ] || { echo "stub devbox: unexpected $*" >&2; exit 2; }
shift 2
exec "$@"
STUB
cat > "$work/bin/just" <<'STUB'
#!/usr/bin/env bash
if [ "$1" = --summary ]; then
  [ -z "${JUST_MISSING:-}" ] || exit 127
  echo "${RECIPES:-}"; exit 0
fi
echo "just $*" >> "$TOOL_LOG"
[ "${JUST_FAIL:-}" != "$1" ] || exit 1
STUB
cat > "$work/bin/pkl" <<'STUB'
#!/usr/bin/env bash
echo "pkl $*" >> "$TOOL_LOG"
[ -z "${PKL_FAIL:-}" ] || exit 1
STUB
chmod +x "$work/bin/"*

FAKE="$work/fake"
fake() { # <METHOD> <path> <content>
  mkdir -p "$FAKE"
  printf '%s' "$3" > "$FAKE/$(printf '%s' "$1$2" | tr -c 'A-Za-z0-9.\n-' '_')"
}
reset_fake() { rm -rf "$FAKE"; mkdir -p "$FAKE"; : > "$FAKE/calls"; }
ncalls() { grep -c "$1" "$FAKE/calls" || true; }

# ── target ───────────────────────────────────────────────────────────────
run_target() { # <version input>
  : > "$work/gh_out"
  PATH="$work/bin:$PATH" FAKE="$FAKE" VERSION="$1" SOURCE="${SOURCE:-o/lib}" API=https://api.test TOKEN=t \
    GITHUB_OUTPUT="$work/gh_out" bash "$work/target.sh" >"$work/out" 2>"$work/err"
}
target_ok() { # <label> <input> <want>
  if ! run_target "$2"; then nope "$1: refused: $(cat "$work/out")"; return; fi
  [ "$(cat "$work/gh_out")" = "version=$3" ] && pass "$1" || nope "$1: output [$(cat "$work/gh_out")], want version=$3"
}
target_refused() { # <label> <input> <substring>
  if run_target "$2"; then nope "$1: accepted, want a refusal"; return; fi
  grep -q -- "$3" "$work/out" && pass "$1 refused" || nope "$1: refusal says [$(cat "$work/out")], want [$3]"
}
reset_fake
fake GET /repos/o/lib/releases/latest '{"tag_name":"v0.4.1"}'
fake GET /repos/o/lib/releases/tags/v0.4.1 '{}'
fake GET /repos/o/lib/releases/tags/v0.3.0 '{}'
fake GET /repos/o/lib/releases/tags/v1.0.0-rc.1 '{}'
target_ok "empty: the latest release" "" 0.4.1
target_ok "explicit, with a v" v0.3.0 0.3.0
target_ok "explicit, without a v" 0.3.0 0.3.0
target_ok "a prerelease, explicitly" 1.0.0-rc.1 1.0.0-rc.1
target_refused "explicit but never released" 0.9.9 "no published release v0.9.9"
target_refused "not a version" 1.2 "is not a version"
target_refused "a branch name" main "is not a version"
SOURCE='o/lib; rm' target_refused "a source that is not owner/name" "" "is not owner/name"
rm "$FAKE"/GET_repos_o_lib_releases_latest
target_refused "no latest release" "" "could not read the latest release"
fake GET /repos/o/lib/releases/latest '{"tag_name":null}'
target_refused "latest without a tag" "" "has no release"

# ── consumers ────────────────────────────────────────────────────────────
reset_fake
U=package://github.com/o/lib/releases/download
tree() { # <path>...   a git tree listing of blobs
  jq -nc --argjson t "${TRUNC:-false}" '{truncated: $t, tree: ($ARGS.positional | map({path: ., type: "blob"}))}' --args "$@"
}
repo_fake() { # <name> <tree paths...>
  fake GET "/repos/o/$1" '{"default_branch":"main"}'
  local n="$1"; shift
  fake GET "/repos/o/$n/git/trees/main?recursive=1" "$(tree "$@")"
}
pkl_at() { printf 'amends "pkl:Project"\ndependencies {\n  ["vocab"] { uri = "%s/v%s/contracts.vocab@%s" }\n}\n' "$U" "$1" "$1"; }
raw() { fake GET "/repos/o/$1/contents/$2?ref=main" "$3"; }
repo_fake r1 devbox.json PklProject README.md;                 raw r1 PklProject "$(pkl_at 0.2.0)"
repo_fake r2 devbox.json svc/PklProject svc/PklProject.deps.json; raw r2 svc/PklProject "$(pkl_at 0.2.0)"
repo_fake r3 devbox.json README.md
repo_fake r4 devbox.json PklProject;                           raw r4 PklProject 'amends "pkl:Project"
dependencies { ["x"] { uri = "package://github.com/other/lib/releases/download/v1.0.0/x@1.0.0" } }'
repo_fake r5 PklProject;                                       raw r5 PklProject "$(pkl_at 0.2.0)"
fake GET /repos/o/r6 '{"default_branch":"main"}'
repo_fake r7 devbox.json PklProject;                           raw r7 PklProject "$(pkl_at 0.3.0)"
repo_fake r8 devbox.json a/PklProject b/PklProject;            raw r8 a/PklProject "$(pkl_at 0.3.0)"; raw r8 b/PklProject "$(pkl_at 0.2.0)"
run_consumers() { # <repos json> <version>
  : > "$work/gh_out"
  PATH="$work/bin:$PATH" FAKE="$FAKE" REPOS="$1" SOURCE=o/lib VERSION="$2" API=https://api.test TOKEN=t \
    GITHUB_OUTPUT="$work/gh_out" bash "$work/consumers.sh" >"$work/out" 2>"$work/err"
}
run_consumers '["o/r1","o/r2","o/r3","o/r4","o/r5","o/r6","o/r7","o/r8"]' 0.3.0 || nope "consumers: failed: $(cat "$work/out")"
[ "$(sed -n 's/^repositories=//p' "$work/gh_out")" = '["o/r1","o/r2","o/r8"]' ] \
  && pass "consumers: the stale ones only (a nested PklProject, one of two stale)" \
  || nope "consumers: got [$(cat "$work/gh_out")]"
[ "$(sed -n 's/^count=//p' "$work/gh_out")" = 3 ] && pass "  count" || nope "  count"
grep -q "o/r7: already at v0.3.0" "$work/out" && pass "  a repository already current is left out" || nope "  r7: $(cat "$work/out")"
grep -q "o/r4: PklProject files do not depend" "$work/out" && pass "  a PklProject on another library is not a consumer" || nope "  r4"
grep -q "o/r3: no PklProject" "$work/out" && pass "  no PklProject, no consumer" || nope "  r3"
grep -q "::error::o/r5: depends on o/lib but has no devbox.json" "$work/out" && pass "  no devbox.json is an error annotation" || nope "  r5"
grep -q "::error::o/r6: could not read the tree" "$work/out" && pass "  an unreadable repository is an error annotation and the rest still run" || nope "  r6: $(cat "$work/out")"
run_consumers '["o/r1"]' 0.2.0 && [ "$(sed -n 's/^count=//p' "$work/gh_out")" = 0 ] && pass "  at the target everywhere: nothing to do" || nope "  target-current: $(cat "$work/gh_out")"
TRUNC=true repo_fake r9 devbox.json PklProject; raw r9 PklProject "$(pkl_at 0.1.0)"
run_consumers '["o/r9"]' 0.3.0 && grep -q "truncated" "$work/out" && pass "  a truncated tree warns" || nope "  truncated: $(cat "$work/out")"

# ── rewrite ──────────────────────────────────────────────────────────────
# A consumer's checkout: a root project and a nested one, each with the
# deps.json a REMOTE resolve writes (the major-only key, the projectpackage
# value, a checksum).
deps_json() { # <version> <name>...
  local v="$1" first=1; shift
  printf '{\n  "schemaVersion": 1,\n  "resolvedDependencies": {\n'
  for n in "$@"; do
    [ "$first" = 1 ] || printf ',\n'; first=0
    printf '    "%s/v%s/contracts.%s@%s": {\n      "type": "remote",\n      "uri": "projectpackage://github.com/o/lib/releases/download/v%s/contracts.%s@%s",\n      "checksums": {\n        "sha256": "abc%s"\n      }\n    }' "$U" "$v" "$n" "${v%%.*}" "$v" "$n" "$v" "$n"
  done
  printf '\n  }\n}\n'
}
mk_repo() { # <root version> <nested version>
  local r="$work/consumer"
  rm -rf "$r"; mkdir -p "$r/svc"
  {
    echo '// consumer project'
    echo 'amends "pkl:Project"'
    echo 'dependencies {'
    echo "  [\"vocab\"] { uri = \"$U/v$1/contracts.vocab@$1\" }"
    echo "  [\"model\"] { uri = \"$U/v$1/contracts.model@$1\" }"
    echo '  ["other"] { uri = "package://github.com/someone/else/releases/download/v1.0.0/else.pkg@1.0.0" }'
    echo '}'
  } > "$r/PklProject"
  deps_json "$1" vocab model > "$r/PklProject.deps.json"
  {
    echo 'amends "pkl:Project"'
    echo 'dependencies {'
    echo "  [\"vocab\"] { uri = \"$U/v$2/contracts.vocab@$2\" }"
    echo '}'
    echo "// import \"$U/v$2/contracts.vocab@$2#/Vocab.pkl\""
  } > "$r/svc/PklProject"
  deps_json "$2" vocab > "$r/svc/PklProject.deps.json"
  echo 'plain' > "$r/README.md"
  ( cd "$r" && git init -q . && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init )
}
run_rewrite() { # <target>
  : > "$work/gh_out"
  ( cd "$work/consumer" && TARGET="$1" SOURCE=o/lib DIRS_FILE="$work/dirs" GITHUB_OUTPUT="$work/gh_out" \
      bash "$work/rewrite.sh" ) >"$work/out" 2>"$work/err"
}
out_of() { sed -n "s/^$1=//p" "$work/gh_out"; }
snapshot() { ( cd "$work/consumer" && cat PklProject PklProject.deps.json svc/PklProject svc/PklProject.deps.json README.md | sha256sum ); }
no_stale() { # nothing of the old version left in the tracked files
  ! ( cd "$work/consumer" && grep -rn "v$1\|@$1" PklProject PklProject.deps.json svc/PklProject svc/PklProject.deps.json )
}

mk_repo 0.2.0 0.2.0
run_rewrite 0.2.1 && pass "rewrite 0.2.0 -> 0.2.1" || nope "rewrite: $(cat "$work/out")"
c="$work/consumer"
no_stale 0.2.0 && pass "  no old version left, in any of the four files" || nope "  stale: $(cd "$c" && grep -rn '0\.2\.0' PklProject* svc | head -3)"
grep -q "\[\"vocab\"\] { uri = \"$U/v0.2.1/contracts.vocab@0.2.1\" }" "$c/PklProject" && pass "  PklProject: the package URI form" || nope "  PklProject: $(cat "$c/PklProject")"
grep -q "\"$U/v0.2.1/contracts.vocab@0\": {" "$c/PklProject.deps.json" && pass "  deps.json: the major-only key keeps its @0" || nope "  deps.json key"
grep -q "\"uri\": \"projectpackage://github.com/o/lib/releases/download/v0.2.1/contracts.vocab@0.2.1\"" "$c/PklProject.deps.json" && pass "  deps.json: the projectpackage value" || nope "  deps.json uri"
grep -q "\"sha256\": \"abcvocab\"" "$c/PklProject.deps.json" && pass "  deps.json: checksums are left for resolve to rewrite" || nope "  checksum touched"
grep -q "import \"$U/v0.2.1/contracts.vocab@0.2.1#/Vocab.pkl\"" "$c/svc/PklProject" && pass "  a URI with a #/module suffix" || nope "  suffix form: $(cat "$c/svc/PklProject")"
grep -q 'someone/else/releases/download/v1.0.0/else.pkg@1.0.0' "$c/PklProject" && pass "  another library's URI is untouched" || nope "  other library touched"
grep -q '^plain$' "$c/README.md" && pass "  nothing else is touched" || nope "  README"
[ "$(sort "$work/dirs" | paste -sd' ' -)" = ". svc" ] && pass "  both project directories listed" || nope "  dirs: $(cat "$work/dirs")"
[ "$(out_of changed)" = true ] && [ "$(out_of breaking)" = false ] && [ "$(out_of from)" = 0.2.0 ] && pass "  changed, not breaking, from 0.2.0" || nope "  outputs: $(cat "$work/gh_out")"
before=$(snapshot)
run_rewrite 0.2.1 && pass "already current: accepted" || nope "no-op refused: $(cat "$work/out")"
[ "$(snapshot)" = "$before" ] && [ "$(out_of changed)" = false ] && [ ! -s "$work/dirs" ] && pass "  a no-op: files byte-identical, changed=false, no directories" || nope "  no-op changed something: $(cat "$work/gh_out")"

mk_repo 0.2.0 0.2.1
run_rewrite 0.2.1 && [ "$(cat "$work/dirs")" = . ] && [ "$(out_of from)" = 0.2.0 ] && pass "only the stale project is rewritten" || nope "  partial: dirs [$(cat "$work/dirs")] $(cat "$work/gh_out")"
mk_repo 0.2.0 0.2.1
run_rewrite 0.2.2 && [ "$(out_of from)" = 0.2.0,0.2.1 ] && [ "$(out_of breaking)" = false ] && pass "projects on two versions, both moved" || nope "  mixed: $(cat "$work/gh_out")"

mk_repo 0.2.0 0.2.0
run_rewrite 0.3.0 && [ "$(out_of breaking)" = true ] && pass "a 0.x minor is breaking" || nope "  0.3.0: $(cat "$work/gh_out")"
no_stale 0.2.0 && grep -q "contracts.vocab@0\": {" "$work/consumer/PklProject.deps.json" && pass "  the @0 key stays for another 0.x" || nope "  key after 0.3.0"
mk_repo 0.2.0 0.2.0
run_rewrite 1.0.0 && [ "$(out_of breaking)" = true ] && pass "a new major is breaking" || nope "  1.0.0: $(cat "$work/gh_out")"
grep -q "\"$U/v1.0.0/contracts.vocab@1\": {" "$work/consumer/PklProject.deps.json" && ! grep -q '@0"' "$work/consumer/PklProject.deps.json" \
  && pass "  the major-only keys move to @1" || nope "  keys after 1.0.0: $(grep '@' "$work/consumer/PklProject.deps.json" | head -2)"
mk_repo 1.0.0 1.0.0
run_rewrite 1.0.1 && [ "$(out_of breaking)" = false ] && grep -q "contracts.vocab@1\": {" "$work/consumer/PklProject.deps.json" && pass "a 1.x patch is not breaking, @1 keys stay" || nope "  1.0.1: $(cat "$work/gh_out")"
mk_repo 1.0.0 1.0.0
run_rewrite 1.1.0 && [ "$(out_of breaking)" = false ] && pass "a 1.x minor is not breaking" || nope "  1.1.0: $(cat "$work/gh_out")"
mk_repo 0.2.0 0.2.0
run_rewrite 0.2.1-rc.1 && [ "$(out_of breaking)" = true ] && grep -q "v0.2.1-rc.1/contracts.vocab@0.2.1-rc.1" "$work/consumer/PklProject" && pass "a prerelease target is rewritten and treated as breaking" || nope "  rc: $(cat "$work/gh_out")"

rewrite_refused() { # <label> <substring> <target>   (consumer already damaged by the caller)
  local b; b=$(snapshot)
  if run_rewrite "$3"; then nope "$1: accepted, want a refusal"; return; fi
  grep -q -- "$2" "$work/out" || { nope "$1: refusal says [$(cat "$work/out")], want [$2]"; return; }
  [ "$(snapshot)" = "$b" ] && pass "$1 refused, nothing written" || nope "$1: refused but wrote files"
}
mk_repo 0.2.0 0.2.0; sed -i 's#v0.2.0/contracts.model@0.2.0#v0.2.0/contracts.model@0.1.0#' "$work/consumer/PklProject"
rewrite_refused "tag and package version disagree" "names release v0.2.0 but package version 0.1.0" 0.2.1
mk_repo 0.2.0 0.2.0; sed -i 's#contracts.model@0.2.0#contracts.model@latest#' "$work/consumer/PklProject"
rewrite_refused "a floating version" "not of the shape" 0.2.1
mk_repo 0.2.0 0.2.0; sed -i 's#download/v0.2.0/contracts.model#download/0.2.0/contracts.model#' "$work/consumer/PklProject"
rewrite_refused "a tag without its v" "not of the shape" 0.2.1
mk_repo 0.2.0 0.2.0; sed -i 's#download/v0.2.0/contracts.vocab@0.2.0"#download/v0.2/contracts.vocab@0.2"#' "$work/consumer/svc/PklProject"
rewrite_refused "a malformed URI in a second project stops the first from being written" "not of the shape" 0.2.1
mk_repo 0.2.0 0.2.0; sed -i '0,/contracts.vocab@0"/s##contracts.vocab@7"#' "$work/consumer/PklProject.deps.json"
rewrite_refused "a major-only key that is not the release's major" "has major 7 but release v0.2.0" 0.2.1
mk_repo 0.3.0 0.3.0
rewrite_refused "a downgrade" "refusing to downgrade" 0.2.0
mk_repo 0.2.0 0.2.0; rewrite_refused "a target that is not a version" "is not a version" latest
mk_repo 0.2.0 0.2.0; rewrite_refused "a target with a shell in it" "is not a version" '0.2.1;touch x'
( cd "$work/consumer" && git rm -q PklProject svc/PklProject )
if run_rewrite 0.2.1; then nope "no PklProject at all: accepted"
elif grep -q "no PklProject" "$work/out"; then pass "no PklProject at all refused"
else nope "no PklProject: [$(cat "$work/out")]"; fi

# ── resolve ──────────────────────────────────────────────────────────────
tlog="$work/tools.log"
run_resolve() { # <recipes>
  : > "$tlog"
  # from $work, where `bin/pkl` is the stub
  ( cd "$work" && PATH="$work/bin:$PATH" TOOL_LOG="$tlog" RECIPES="$1" DIRS_FILE="$work/dirs" PKL_COMMAND="${PKL_COMMAND:-pkl}" \
      bash "$work/resolve.sh" ) >"$work/out" 2>"$work/err"
}
printf '.\nsvc\n' > "$work/dirs"
run_resolve "test resolve generate lint" && pass "resolve and generate recipes" || nope "recipes: $(cat "$work/out")"
[ "$(paste -sd';' "$tlog")" = "just resolve;just generate" ] && pass "  the repository's own recipes, in that order, and no direct pkl" || nope "  calls: $(paste -sd';' "$tlog")"
run_resolve "test lint" && pass "no recipes" || nope "no recipes: $(cat "$work/out")"
[ "$(paste -sd';' "$tlog")" = "pkl project resolve .;pkl project resolve svc" ] && pass "  pkl project resolve for each rewritten project, no generate" || nope "  calls: $(paste -sd';' "$tlog")"
PKL_COMMAND=bin/pkl run_resolve "" && [ "$(head -1 "$tlog")" = "pkl project resolve ." ] && pass "  pkl-command is what runs" || nope "  pkl-command: $(cat "$tlog")"
run_resolve "generate" && [ "$(paste -sd';' "$tlog")" = "pkl project resolve .;pkl project resolve svc;just generate" ] && pass "a generate recipe without a resolve recipe: direct resolve, then generate" || nope "  calls: $(paste -sd';' "$tlog")"
JUST_MISSING=1 run_resolve "resolve generate" && [ "$(paste -sd';' "$tlog")" = "pkl project resolve .;pkl project resolve svc" ] && pass "no just in the devbox: direct resolve" || nope "  no just: $(paste -sd';' "$tlog")"
run_resolve "resolvex regenerate" && [ "$(grep -c '^just' "$tlog")" = 0 ] && pass "recipe names are matched whole" || nope "  prefix match: $(cat "$tlog")"
JUST_FAIL=resolve run_resolve "resolve generate" && nope "a failing resolve passed" || { [ "$(grep -c generate "$tlog")" = 0 ] && pass "a failing resolve fails the job before generate" || nope "  generate ran after a failed resolve"; }
JUST_FAIL=generate run_resolve "resolve generate" && nope "a failing generate passed" || pass "a failing generate fails the job"
PKL_FAIL=1 run_resolve "" && nope "a failing direct resolve passed" || pass "a failing direct resolve fails the job"

# ── publish ──────────────────────────────────────────────────────────────
origin="$work/origin.git"; clone="$work/clone"
mk_clone() {
  rm -rf "$origin" "$clone"
  git init -q --bare -b main "$origin"
  git init -q -b main "$clone"
  ( cd "$clone"
    git remote add origin "$origin"
    echo 'v1' > PklProject
    git add -A && git -c user.name=t -c user.email=t@t commit -q -m base
    git push -q origin main )
}
change() { ( cd "$clone" && echo 'v2' > PklProject ); }
printf '.\nsvc\n' > "$work/dirs"
: > "$work/summary"
run_publish() { # extra env as args
  : > "$work/gh_out"
  ( cd "$clone" && env PATH="$work/bin:$PATH" FAKE="$FAKE" TOKEN=secret-token REPO=o/r BASE=main API=https://api.test \
      SOURCE=o/lib VERSION=0.3.0 FROM=0.2.0 BREAKING=false DIRS_FILE="$work/dirs" BRANCH_PREFIX=pkl-contracts- \
      DRY_RUN=false AUTO_MERGE=true GIT_USER='fleet[bot]' GIT_EMAIL=bot@example GITHUB_OUTPUT="$work/gh_out" \
      GITHUB_STEP_SUMMARY="$work/summary" "$@" bash "$work/publish.sh" ) >"$work/out" 2>"$work/err"
}
remote_ref() { git -C "$origin" rev-parse --quiet --verify "refs/heads/pkl-contracts-0.3.0" || echo none; }
pr_fakes() {
  reset_fake
  fake GET '/repos/o/r/pulls?state=open&head=o:pkl-contracts-0.3.0&per_page=100' '[]'
  fake GET '/repos/o/r/pulls?state=open&per_page=100' '[]'
  fake POST /repos/o/r/pulls '{"number":7,"html_url":"https://example.test/o/r/pull/7","node_id":"PR_node7"}'
  fake POST /graphql '{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}'
}

mk_clone; change; pr_fakes
run_publish DRY_RUN=true && pass "dry run" || nope "dry run: $(cat "$work/out")"
[ "$(remote_ref)" = none ] && [ ! -s "$FAKE/calls" ] && pass "  nothing pushed, no API call at all" || nope "  dry run acted: ref $(remote_ref), calls $(cat "$FAKE/calls")"
grep -q 'dry run' "$work/summary" && pass "  reported in the summary" || nope "  summary"

mk_clone; pr_fakes
run_publish && pass "nothing changed" || nope "unchanged: $(cat "$work/out")"
[ "$(remote_ref)" = none ] && [ ! -s "$FAKE/calls" ] && pass "  no branch, no pull request" || nope "  unchanged acted"

mk_clone; change; pr_fakes
fake GET '/repos/o/r/pulls?state=open&per_page=100' '[{"number":3,"head":{"ref":"pkl-contracts-0.2.1","repo":{"full_name":"o/r"}}},{"number":4,"head":{"ref":"renovate/x","repo":{"full_name":"o/r"}}},{"number":5,"head":{"ref":"pkl-contracts-0.0.1","repo":{"full_name":"fork/r"}}},{"number":7,"head":{"ref":"pkl-contracts-0.3.0","repo":{"full_name":"o/r"}}}]'
run_publish && pass "a bump, auto-merge on" || nope "publish: $(cat "$work/out") $(cat "$work/err")"
[ "$(remote_ref)" != none ] && pass "  branch pushed" || nope "  no branch"
[ "$(git -C "$origin" log -1 --format=%an:%s refs/heads/pkl-contracts-0.3.0)" = 'fleet[bot]:chore(deps): update lib to v0.3.0' ] && pass "  commit by the bot, conventional title" || nope "  commit: $(git -C "$origin" log -1 --format=%an:%s refs/heads/pkl-contracts-0.3.0)"
[ "$(ncalls '^POST /repos/o/r/pulls ')" = 1 ] && grep -q '"head":"pkl-contracts-0.3.0"' "$FAKE/calls" && grep -q '"base":"main"' "$FAKE/calls" && pass "  one pull request, head and base" || nope "  create: $(grep pulls "$FAKE/calls")"
grep -q 'POST /repos/o/r/issues/7/labels {"labels":\["dependencies"\]}' "$FAKE/calls" && pass "  labelled dependencies, not major" || nope "  labels: $(grep labels "$FAKE/calls")"
[ "$(ncalls '/graphql')" = 1 ] && grep -q 'enablePullRequestAutoMerge' "$FAKE/calls" && grep -q 'REBASE' "$FAKE/calls" && grep -q 'PR_node7' "$FAKE/calls" && pass "  auto-merge armed (rebase)" || nope "  graphql: $(grep graphql "$FAKE/calls")"
grep -q 'POST /repos/o/r/issues/3/comments' "$FAKE/calls" && grep -q 'PATCH /repos/o/r/pulls/3 {"state":"closed"}' "$FAKE/calls" && grep -q 'DELETE /repos/o/r/git/refs/heads/pkl-contracts-0.2.1' "$FAKE/calls" \
  && pass "  the older pull request is closed as superseded and its branch deleted" || nope "  supersede: $(cat "$FAKE/calls")"
[ "$(ncalls 'issues/4\|issues/5\|pulls/4\|pulls/5\|pulls/7 ')" = 0 ] && pass "  an unrelated, a fork's and the new pull request are not touched" || nope "  over-closed: $(cat "$FAKE/calls")"
grep -q 'https://example.test/o/r/pull/7' "$work/gh_out" && pass "  the URL is an output" || nope "  output: $(cat "$work/gh_out")"
grep -rq 'secret-token' "$clone/.git" 2>/dev/null && nope "  the token reached the clone's .git" || pass "  the token is in no git config"
grep -q 'dependencies' "$FAKE/calls" && ! grep -q 'secret-token' "$work/out" && pass "  the token is not printed" || nope "  token in output"

# the same change again: the open pull request is updated, the branch is not pushed
sha=$(remote_ref)
( cd "$clone" && git checkout -q main && git branch -q -D pkl-contracts-0.3.0 ); change
pr_fakes
fake GET '/repos/o/r/pulls?state=open&head=o:pkl-contracts-0.3.0&per_page=100' '[{"number":7,"html_url":"https://example.test/o/r/pull/7","node_id":"PR_node7"}]'
run_publish && pass "a re-run with an open pull request" || nope "re-run: $(cat "$work/out")"
[ "$(remote_ref)" = "$sha" ] && pass "  identical content is not pushed again" || nope "  re-pushed identical content"
[ "$(ncalls '^POST /repos/o/r/pulls ')" = 0 ] && [ "$(ncalls '^PATCH /repos/o/r/pulls/7 ')" = 1 ] && pass "  the pull request is updated, not opened again" || nope "  update: $(cat "$FAKE/calls")"
( cd "$clone" && git checkout -q main && git branch -q -D pkl-contracts-0.3.0 ); ( cd "$clone" && echo 'v3' > PklProject )
run_publish && [ "$(remote_ref)" != "$sha" ] && pass "  different content is force-pushed" || nope "  different content not pushed"

mk_clone; change; pr_fakes
run_publish BREAKING=true && pass "a breaking bump" || nope "breaking: $(cat "$work/out")"
grep -q '"labels":\["dependencies","major"\]' "$FAKE/calls" && [ "$(ncalls '/graphql')" = 0 ] && pass "  labelled major, never auto-merged" || nope "  breaking: $(cat "$FAKE/calls")"
grep -q 'POST /repos/o/r/labels' "$FAKE/calls" && pass "  the labels are created if missing" || nope "  labels not created"

mk_clone; change; pr_fakes
run_publish AUTO_MERGE=false && [ "$(ncalls '/graphql')" = 0 ] && pass "auto-merge off (or no required check): not armed" || nope "  armed anyway"
mk_clone; change; pr_fakes
fake POST /graphql '{"errors":[{"message":"Auto merge is not allowed for this repository"}]}'
run_publish && grep -q '::warning::.*could not be armed' "$work/out" && pass "an auto-merge the repository refuses is a warning, not a failure" || nope "  refusal: $(cat "$work/out")"

[ "$fail" = 0 ] && echo "pkl-fleet cases passed"
exit "$fail"
