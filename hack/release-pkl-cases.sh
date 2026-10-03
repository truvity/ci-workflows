#!/usr/bin/env bash
# Cases for release-pkl.yaml: the version, tag and changelog refusals, the
# asset check, the publish step's re-run behaviour against a stubbed `gh`, and
# the smoke test's resolve and imports against a stubbed Pkl. Each block
# between the `>>> name` and `<<< name` markers is lifted out of the workflow
# and run as written, so what is asserted is what a release runs.
#
#   hack/release-pkl-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/release-pkl.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

block() {
  awk -v n="$1" '$0 ~ "# >>> " n " "{on=1} on{print} $0 ~ "# <<< " n{on=0}' "$wf" | sed 's/^          //' > "$work/$1.sh"
  [ -s "$work/$1.sh" ] || { echo "no $1 block found"; exit 1; }
}
for b in checks assets publish smoke notify; do block "$b"; done

mkdir "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
# A release store in $STATE: `exists`, `assets/`, and a `calls` log.
if [ "$1" = api ]; then
  # The notify dispatch: logged with the token it was sent with; $GH_API_FAIL refuses it.
  echo "api $GH_TOKEN $*" >> "$STATE/api_calls"
  [ -z "${GH_API_FAIL:-}" ] || { echo "HTTP 403: Resource not accessible by integration" >&2; exit 1; }
  exit 0
fi
[ "$1" = release ] || { echo "stub gh: unexpected $*" >&2; exit 2; }
cmd="$2"; shift 2
echo "$cmd $*" >> "$STATE/calls"
case "$cmd" in
  view)
    [ -f "$STATE/exists" ] || exit 1
    case "$*" in *--json*) ls "$STATE/assets" ;; esac ;;
  create) touch "$STATE/exists"; mkdir -p "$STATE/assets" ;;
  upload)
    shift   # the tag
    while [ $# -gt 0 ]; do
      case "$1" in --repo) shift 2 ;; *) cp "$1" "$STATE/assets/${1##*/}"; shift ;; esac
    done ;;
  download)
    pat=""; dir=""
    while [ $# -gt 0 ]; do
      case "$1" in --pattern) pat="$2"; shift 2 ;; --dir) dir="$2"; shift 2 ;; *) shift ;; esac
    done
    cp "$STATE/assets/$pat" "$dir/$pat" ;;
  *) echo "stub gh: unexpected release $cmd" >&2; exit 2 ;;
esac
STUB
cat > "$work/bin/pkl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$PKL_LOG"
if [ "${PKL_FAIL:-}" = "$1 $2" ] || [ "${PKL_FAIL:-}" = "$1" ]; then exit 1; fi
# the first N attempts of a resolve fail, to exercise the retry
if [ "$1 $2" = "project resolve" ] && [ "${PKL_FLAKY:-0}" -gt 0 ]; then
  n=$(wc -l < "$PKL_LOG")
  [ "$n" -gt "$PKL_FLAKY" ] || exit 1
fi
exit 0
STUB
chmod +x "$work/bin/gh" "$work/bin/pkl"

fail=0
pass() { echo "ok    $1"; }
nope() { echo "FAIL  $1"; fail=1; }

# ── checks ───────────────────────────────────────────────────────────────
cat > "$work/CHANGELOG.md" <<'MD'
# Changelog

## Unreleased

- Not yet.

## v0.2.0 — 2026-10-01

- Second.

## v0.1.0

- First.
- Another.

## v0.0.9

- Older.
MD
# run_checks <ref_type> <tag> <declared>
run_checks() {
  : > "$work/gh_out"
  REF_TYPE="$1" TAG="$2" DECLARED="$3" CHANGELOG="${CHANGELOG_FILE:-$work/CHANGELOG.md}" \
    NOTES_FILE="$work/notes.md" GITHUB_OUTPUT="$work/gh_out" bash "$work/checks.sh" >"$work/out" 2>"$work/err"
}
checks_ok() { # <label> <tag> <declared> <expected version>
  if ! run_checks tag "$2" "$3"; then nope "$1: refused: $(cat "$work/out")"; return; fi
  if [ "$(cat "$work/gh_out")" != "version=$4" ]; then nope "$1: output [$(cat "$work/gh_out")], want version=$4"; return; fi
  pass "$1"
}
checks_refused() { # <label> <ref_type> <tag> <declared> <substring>
  if run_checks "$2" "$3" "$4"; then nope "$1: accepted, want a refusal"; return; fi
  if ! grep -q -- "$5" "$work/out"; then nope "$1: refusal says [$(cat "$work/out")], want [$5]"; return; fi
  pass "$1 refused"
}
checks_ok "tag equals declared" v0.1.0 0.1.0 0.1.0
checks_ok "heading with a date suffix" v0.2.0 0.2.0 0.2.0
checks_ok "nothing declared: the tag is the version" v0.1.0 "" 0.1.0
checks_refused "tag differs from declared" tag v0.1.0 0.2.0 "is not v plus the declared version"
checks_refused "declared differs from tag" tag v0.2.0 0.1.0 "is not v plus the declared version"
checks_refused "tag without v" tag 0.1.0 0.1.0 "does not start with v"
checks_refused "branch push" branch v0.1.0 0.1.0 "not on a branch"
checks_refused "declared is not a version" tag v1 1 "is not a version"
checks_refused "declared with a v" tag vv0.1.0 v0.1.0 "is not a version"
checks_refused "nothing declared, tag not a version" tag vnext "" "is not a version"
checks_refused "no heading for the version" tag v0.3.0 0.3.0 "no '## v0.3.0' heading"
checks_refused "a prefix of a heading is not a heading" tag v0.0.1 0.0.1 "no '## v0.0.1' heading"
if CHANGELOG_FILE="$work/none.md" run_checks tag v0.1.0 0.1.0; then nope "missing changelog accepted"
elif grep -q "not found" "$work/out"; then pass "missing changelog refused"
else nope "missing changelog: [$(cat "$work/out")]"; fi
run_checks tag v0.1.0 0.1.0
if [ "$(cat "$work/notes.md")" = "$(printf -- '\n- First.\n- Another.\n')" ]; then pass "notes are the heading's section only"
else nope "notes are [$(cat "$work/notes.md")]"; fi
printf '## Unreleased\n\n## v1.0.0-rc.1\n\n- rc.\n' > "$work/pre.md"
CHANGELOG_FILE="$work/pre.md" checks_ok "prerelease version" v1.0.0-rc.1 1.0.0-rc.1 1.0.0-rc.1

# ── assets ───────────────────────────────────────────────────────────────
# mk_out <dir> : two packages at 0.1.0 in the layout `pkl project package` writes
mk_out() {
  local d="$1" p
  rm -rf "$d"
  for p in a.one a.two; do
    mkdir -p "$d/$p@0.1.0"
    printf 'meta %s' "$p" > "$d/$p@0.1.0/$p@0.1.0"
    printf 'zip %s' "$p" > "$d/$p@0.1.0/$p@0.1.0.zip"
    for f in "$p@0.1.0" "$p@0.1.0.zip"; do
      printf '%s' "$(sha256sum "$d/$p@0.1.0/$f" | cut -d' ' -f1)" > "$d/$p@0.1.0/$f.sha256"
    done
  done
}
run_assets() {
  OUTPUT_DIR="$1" VERSION="${2:-0.1.0}" MANIFEST="$work/manifest" bash "$work/assets.sh" >"$work/out" 2>"$work/err"
}
assets_ok() { if run_assets "$2" "${3:-}"; then pass "$1"; else nope "$1: refused: $(cat "$work/out")"; fi; }
assets_refused() { # <label> <dir> <substring> [version]
  if run_assets "$2" "${4:-}"; then nope "$1: accepted, want a refusal"; return; fi
  if grep -q -- "$3" "$work/out"; then pass "$1 refused"; else nope "$1: refusal says [$(cat "$work/out")], want [$3]"; fi
}
o="$work/o"
mk_out "$o"; assets_ok "two packages, four assets each" "$o"
[ "$(wc -l < "$work/manifest")" = 8 ] && pass "manifest lists all eight" || nope "manifest has $(wc -l < "$work/manifest") lines"
mk_out "$o"; rm "$o/a.two@0.1.0/a.two@0.1.0.zip.sha256"
assets_refused "asset without a checksum" "$o" "has no a.two@0.1.0.zip.sha256"
mk_out "$o"; rm "$o/a.one@0.1.0/a.one@0.1.0.zip"
assets_refused "checksum without an asset" "$o" "has no asset beside it"
mk_out "$o"; printf 'beef' > "$o/a.one@0.1.0/a.one@0.1.0.sha256"
assets_refused "checksum of other bytes" "$o" "is not the checksum of a.one@0.1.0"
mk_out "$o"; assets_refused "names carry another version" "$o" "does not carry @0.2.0" 0.2.0
mk_out "$o"; : > "$o/a.one@0.1.0/README"
assets_refused "a file that carries no version" "$o" "README does not carry @0.1.0"
mk_out "$o"; mkdir "$o/again"; cp "$o/a.one@0.1.0/a.one@0.1.0" "$o/again/"
assets_refused "one name twice" "$o" "under one name"
mkdir -p "$work/empty"; assets_refused "empty output directory" "$work/empty" "holds no files"
assets_refused "no output directory" "$work/missing" "does not exist"
mk_out "$o"; mkdir -p "$o/flat"; mv "$o"/a.*@0.1.0/* "$o/flat/"; rmdir "$o"/a.*@0.1.0
assets_ok "a flat directory is fine too" "$o"

# ── publish ──────────────────────────────────────────────────────────────
mk_out "$o"; find "$o" -type f | LC_ALL=C sort > "$work/manifest"
printf -- '- notes\n' > "$work/notes.md"
state="$work/state"
run_publish() { # [version]
  STATE="$state" PATH="$work/bin:$PATH" GH_TOKEN=x REPO=o/r TAG=v0.1.0 VERSION="${1:-0.1.0}" \
    MANIFEST="$work/manifest" NOTES_FILE="$work/notes.md" WORK="$work/remote" bash "$work/publish.sh" >"$work/out" 2>"$work/err"
}
fresh() { rm -rf "$state"; mkdir -p "$state"; : > "$state/calls"; }
held() { ls "$state/assets" 2>/dev/null | wc -l | tr -d ' '; }
calls() { grep -c "^$1" "$state/calls" || true; }
publish_ok() { if run_publish "${2:-}"; then pass "$1"; else nope "$1: refused: $(cat "$work/out")"; fi; }
publish_refused() {
  if run_publish; then nope "$1: accepted, want a refusal"; return; fi
  if grep -q -- "$2" "$work/out"; then pass "$1 refused"; else nope "$1: refusal says [$(cat "$work/out")], want [$2]"; fi
}

fresh; publish_ok "no release yet: create and upload"
[ "$(calls create)" = 1 ] && [ "$(held)" = 8 ] && pass "  created once, eight assets held" || nope "  create=$(calls create) held=$(held)"
grep -q -- '--verify-tag' "$state/calls" && grep -q -- '--generate-notes' "$state/calls" && grep -q -- "--notes-file $work/notes.md" "$state/calls" \
  && pass "  verifies the tag, takes the changelog notes plus generated ones" || nope "  create flags: $(grep ^create "$state/calls")"
grep -q -- '--prerelease' "$state/calls" && nope "  a final version was marked prerelease" || pass "  a final version is not a prerelease"
fresh; publish_ok "a prerelease version" 1.0.0-rc.1
grep -q -- '--prerelease' "$state/calls" && pass "  marked as a prerelease" || nope "  not marked prerelease"

fresh; mkdir -p "$state/assets"; touch "$state/exists"
for f in $(head -3 "$work/manifest"); do cp "$f" "$state/assets/${f##*/}"; done
publish_ok "release with some assets: resume"
[ "$(calls create)" = 0 ] && [ "$(held)" = 8 ] && pass "  no second create, completed to eight" || nope "  create=$(calls create) held=$(held)"
[ "$(grep ^upload "$state/calls" | tr ' ' '\n' | grep -c '^/')" = 5 ] && pass "  uploaded only the five missing" || nope "  upload: $(grep ^upload "$state/calls")"

publish_ok "re-run on a complete release"
[ "$(calls upload)" = 1 ] && pass "  nothing uploaded again (only the earlier resume)" || nope "  uploads: $(calls upload)"

fresh; mkdir -p "$state/assets"; touch "$state/exists"
cp "$(head -1 "$work/manifest")" "$state/assets/"; printf 'other' > "$state/assets/$(basename "$(head -1 "$work/manifest")")"
publish_refused "an asset with different bytes" "different bytes"
[ "$(calls upload)" = 0 ] && pass "  nothing uploaded on refusal" || nope "  uploaded on refusal"

fresh; mkdir -p "$state/assets"; touch "$state/exists"; printf 'x' > "$state/assets/stray@0.1.0"
publish_refused "an asset the build does not produce" "does not produce"
[ "$(calls upload)" = 0 ] && pass "  nothing uploaded on refusal" || nope "  uploaded on refusal"

# ── smoke ────────────────────────────────────────────────────────────────
log="$work/pkl.log"
run_smoke() { # <smoke-import>
  : > "$log"
  PKL_CMD="$work/bin/pkl" PKL_LOG="$log" REPO=o/r TAG=v0.1.0 VERSION=0.1.0 MANIFEST="$work/manifest" \
    SMOKE_IMPORT="$1" SMOKE_DIR="$work/smoke" SMOKE_ATTEMPTS=3 SMOKE_SLEEPS="" bash "$work/smoke.sh" >"$work/out" 2>"$work/err"
}
base=package://github.com/o/r/releases/download/v0.1.0
run_smoke "" && pass "resolve only" || nope "resolve only: $(cat "$work/out")"
[ "$(wc -l < "$log")" = 1 ] && grep -q '^project resolve --cache-dir .*/project$' "$log" && pass "  one resolve, with a fresh cache" || nope "  pkl calls: $(cat "$log")"
grep -q "p0\"\] { uri = \"$base/a.one@0.1.0\" }" "$work/smoke/project/PklProject" \
  && grep -q "p1\"\] { uri = \"$base/a.two@0.1.0\" }" "$work/smoke/project/PklProject" \
  && ! grep -q '\.zip\|sha256' "$work/smoke/project/PklProject" \
  && pass "  depends on each metadata URI, and only those" || nope "  PklProject: $(cat "$work/smoke/project/PklProject")"

run_smoke $'a.one#/One.pkl\na.two#/sub/Two.pkl' && pass "imports" || nope "imports: $(cat "$work/out")"
grep -q "import(\"$base/a.one@0.1.0#/One.pkl\")" "$work/smoke/smoke.pkl" \
  && grep -q "import(\"$base/a.two@0.1.0#/sub/Two.pkl\")" "$work/smoke/smoke.pkl" \
  && grep -q 'List(m0,m1)' "$work/smoke/smoke.pkl" \
  && grep -q '^eval ' "$log" && pass "  evaluates a module importing both URIs" || nope "  smoke.pkl: $(cat "$work/smoke/smoke.pkl")"

run_smoke "a.nine#/X.pkl" && nope "unknown package accepted" || { grep -q "names no package" "$work/out" && pass "unknown package refused" || nope "unknown package: $(cat "$work/out")"; }
run_smoke "a.one" && nope "entry without a module path accepted" || { grep -q "not <package name>#/<module path>" "$work/out" && pass "entry without a module path refused" || nope "no module path: $(cat "$work/out")"; }
PKL_FAIL="project resolve" run_smoke "" && nope "failed resolve passed" || { grep -q "do not resolve" "$work/out" && pass "a failed resolve fails the job" || nope "failed resolve: $(cat "$work/out")"; }
PKL_FAIL="eval" run_smoke "a.one#/One.pkl" && nope "failed eval passed" || { grep -q "does not evaluate" "$work/out" && pass "a failed evaluation fails the job" || nope "failed eval: $(cat "$work/out")"; }
PKL_FLAKY=2 run_smoke "" && pass "a resolve that fails twice is retried" || nope "retry: $(cat "$work/out")"
PKL_FLAKY=9 run_smoke "" && nope "endless failure passed" || pass "retries are bounded"

# ── notify ───────────────────────────────────────────────────────────────
run_notify() { # <token> <workflow>; env GH_API_FAIL may be set
  rm -rf "$state"; mkdir -p "$state"; : > "$state/api_calls"; : > "$work/summary"
  STATE="$state" PATH="$work/bin:$PATH" GH_TOKEN="$1" NOTIFY_REPOSITORY=o/caller NOTIFY_WORKFLOW="$2" \
    NOTIFY_REF=master VERSION=0.1.0 GITHUB_STEP_SUMMARY="$work/summary" bash "$work/notify.sh" >"$work/out" 2>"$work/err"
}
run_notify tok pkl.yaml && pass "notify: dispatch accepted" || nope "notify: job step failed: $(cat "$work/out")"
grep -q '^api tok api --method POST repos/o/caller/actions/workflows/pkl.yaml/dispatches -f ref=master -f inputs\[version\]=0.1.0$' "$state/api_calls" \
  && [ "$(wc -l < "$state/api_calls")" = 1 ] \
  && pass "  one POST to the workflow's dispatches, with the minted token, ref and version" || nope "  api calls: $(cat "$state/api_calls")"
grep -q 'Dispatched pkl.yaml in o/caller on master for 0.1.0' "$work/summary" && pass "  the summary says it was dispatched" || nope "  summary: $(cat "$work/summary")"
GH_API_FAIL=1 run_notify tok pkl.yaml && pass "notify: a refused dispatch does not fail the step" || nope "notify: a refused dispatch failed the step"
grep -q '^::warning::Dispatching pkl.yaml in o/caller failed (HTTP 403' "$work/out" \
  && grep -q "gh workflow run 'pkl.yaml' --repo 'o/caller' --ref 'master' -f version='0.1.0'" "$work/summary" \
  && pass "  warns, and the summary says what to dispatch by hand" || nope "  out: $(cat "$work/out") summary: $(cat "$work/summary")"
run_notify "" pkl.yaml && pass "notify: no token (a refused exchange) does not fail the step" || nope "notify: no token failed the step"
[ ! -s "$state/api_calls" ] && grep -q '^::warning::No token' "$work/out" && grep -q 'gh workflow run' "$work/summary" \
  && pass "  nothing sent, warns, by-hand line in the summary" || nope "  api: $(cat "$state/api_calls") out: $(cat "$work/out")"
run_notify tok "" && pass "notify: no workflow named does not fail the step" || nope "notify: no workflow failed the step"
[ ! -s "$state/api_calls" ] && grep -q 'without notify-workflow' "$work/out" && pass "  nothing sent, warns" || nope "  out: $(cat "$work/out")"
# Not configured: the job is skipped by its `if`, so nothing here may depend on a notify input.
grep -q "if: inputs.notify-repository != ''" "$wf" && pass "notify: the job is skipped when notify-repository is empty" || nope "notify: the job has no empty-input skip"
awk '/^  notify:/{on=1} on' "$wf" | grep -q 'contents:' && nope "notify: the job holds a contents permission" || pass "notify: the job holds no contents permission"

[ "$fail" = 0 ] && echo "release-pkl cases passed"
exit "$fail"
