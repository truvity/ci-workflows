#!/usr/bin/env bash
# Cases for release-public.yaml's `charts` input: what a plain entry and a
# repository-root path resolve to, and everything that is refused. The block
# between the `>>> charts` and `<<< charts` markers is lifted out of the
# workflow and run as written, so what is asserted is what a release runs.
#
#   hack/chart-paths-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/release-public.yaml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# >>> charts/{on=1} on{print} /# <<< charts/{on=0}' "$wf" | sed 's/^          //' > "$work/block.sh"
[ -s "$work/block.sh" ] || { echo "no charts block found"; exit 1; }
{ echo 'set -euo pipefail'; cat "$work/block.sh"; echo 'for e in "${charts[@]}"; do printf "%s\n" "${e/$'"'"'\t'"'"'/ -> }"; done'; } > "$work/run.sh"

fail=0
# ok <charts-json> <chart-root> <expected output, one line per chart>
ok() {
  local got
  if ! got="$(CHARTS="$1" CHART_ROOT="$2" bash "$work/run.sh" 2>"$work/err")"; then
    echo "FAIL  $1: refused, want success: $(cat "$work/err")"; fail=1; return
  fi
  if [ "$got" != "$3" ]; then
    echo "FAIL  $1: got [$got], want [$3]"; fail=1; return
  fi
  echo "ok    $1"
}
# refused <charts-json> <substring the error must carry>
refused() {
  if CHARTS="$1" CHART_ROOT=charts bash "$work/run.sh" >"$work/out" 2>"$work/err"; then
    echo "FAIL  $1: accepted, want a refusal"; fail=1; return
  fi
  if ! grep -q -- "$2" "$work/err"; then
    echo "FAIL  $1: refusal says [$(cat "$work/err")], want it to carry [$2]"; fail=1; return
  fi
  echo "ok    $1 refused"
}

# What every caller has today: names under chart-root, behaving as before.
ok '["github-roster"]' charts 'charts/github-roster -> github-roster'
ok '["url-shortener","url-shortener-infra"]' examples/url-shortener/charts \
  $'examples/url-shortener/charts/url-shortener -> url-shortener\nexamples/url-shortener/charts/url-shortener-infra -> url-shortener-infra'
ok '["a"]' charts/ 'charts/a -> a'
ok '[]' charts ''

# A repository-root path: chart-root does not apply, the name is the last element.
ok '["charts/service-lib"]' examples/url-shortener/charts 'charts/service-lib -> service-lib'
ok '["url-shortener","charts/service-lib"]' examples/url-shortener/charts \
  $'examples/url-shortener/charts/url-shortener -> url-shortener\ncharts/service-lib -> service-lib'
ok '["libs/shared/common"]' charts 'libs/shared/common -> common'

refused 'not json' 'not a JSON array'
refused '"url-shortener"' 'not a JSON array'
refused '[1]' 'not a non-empty string'
refused '[""]' 'not a non-empty string'
refused '["/charts/x"]' 'absolute'
refused '["../x"]' '`..`'
refused '["charts/../x"]' '`..`'
refused '["charts//x"]' 'empty'
refused '["charts/x/"]' 'empty'
refused '["./x"]' '`.`'
refused '["Upper"]' 'lowercase chart name'
refused '["charts/Upper"]' 'lowercase chart name'
refused '["a b"]' 'lowercase chart name'
refused '["charts/x","other/x"]' 'both published as'
refused '["x","charts/x"]' 'both published as'

[ "$fail" = 0 ] && echo "chart-paths cases passed"
exit "$fail"
