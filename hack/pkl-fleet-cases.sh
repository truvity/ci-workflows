#!/usr/bin/env bash
# Cases for pkl-fleet.yaml: resolving the target version, finding the
# consumers that need a bump. (The rewrite, resolve and pull-request steps
# are the ci-actions `pkl-fleet` action's, tested there.) Each block between the
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
for b in target consumers; do block "$b"; done

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

# ── wiring ───────────────────────────────────────────────────────────────
# setup-devbox reads the consumer's own tool config: it must never be handed
# the App token, only the job's read-only one.
n=$(grep -c 'ci-actions/setup-devbox@' "$wf" || true)
ok=$(awk '/ci-actions\/setup-devbox@/{on=1} on && /github-token:/{print; on=0}' "$wf" | grep -c 'github-token: \${{ github.token }}$' || true)
if [ "$n" -ge 1 ] && [ "$n" = "$ok" ]; then pass "setup-devbox gets only github.token ($n use)"
else nope "setup-devbox wiring: $n uses, $ok with github.token"; fi

[ "$fail" = 0 ] && echo "pkl-fleet cases passed"
exit "$fail"
