#!/usr/bin/env bash
# Each refusal of `hack/runner-sizes.sh check` that guards the caller's
# `runner-sizes` input, proved by breaking a copy of the tree and expecting
# that refusal by name. A guard that cannot fail checks nothing, so the
# unbroken copy must pass too.
#
#   hack/runner-sizes-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# case <name> <expected refusal, or "" for a pass> <mutation, run in the copy>
case_() {
  local name=$1 want=$2 mut=$3 d="$tmp/$1" out rc=0
  mkdir -p "$d"
  cp -r "$root/.github" "$root/hack" "$root/runner-sizes.yaml" "$d/"
  (cd "$d" && eval "$mut")
  out=$(cd "$d" && ./hack/runner-sizes.sh check 2>&1) || rc=$?
  if [ -z "$want" ] && [ "$rc" = 0 ]; then
    echo "ok    $name: passes"
  elif [ -n "$want" ] && [ "$rc" != 0 ] && grep -q "^$want " <<<"$out"; then
    echo "ok    $name: refused as $want"
  else
    echo "FAIL  $name: rc=$rc, wanted ${want:-a pass}"
    sed 's/^/      /' <<<"$out" | tail -5
    fail=1
  fi
}

case_ unchanged "" true

# Each workflow's guards, broken one at a time: <file> <matrix key>.
for wk in check.yaml:recipe integration.yaml:name; do
  wf=${wk%%:*} k=${wk#*:} w=${wk%%.*}
  c="fromJSON\(inputs\.runner-sizes \|\| \x27\{\}\x27\)\[matrix\.$k\]"

  # runs-on stops reading the caller's input first.
  case_ "$w-no-caller-lookup" "NOT CALLER" \
    "perl -0pi -e 's/\(contains\(fromJSON\(\x27\[[^]]*\]\x27\), $c\)\n\s*&& $c\)\n\s*\|\| //' .github/workflows/$wf"

  # runs-on reads it, but no longer only when it is a size: a typo or the
  # name of another organisation variable would reach vars[] again.
  case_ "$w-ungated-caller" "NOT CALLER" \
    "perl -0pi -e 's/\(contains\(fromJSON\(\x27\[[^]]*\]\x27\), $c\)\n\s*&& ($c)\)/\$1/' .github/workflows/$wf"

  # The input's default stops being the empty object, so callers that
  # pass nothing would no longer keep today's sizes.
  case_ "$w-input-default" "NO INPUT" \
    "yq -i '.on.workflow_call.inputs.\"runner-sizes\".default = \"[]\"' .github/workflows/$wf"

  # The step that refuses a bad size forgets one size.
  case_ "$w-size-list-if" "SIZE LIST" \
    "perl -pi -e 's/\"XLARGE\",\"MEDIUM_SPOT\"/\"XLARGE\"/ if /&& !contains\(fromJSON/' .github/workflows/$wf"

  # runs-on's gate forgets one size.
  case_ "$w-size-list-runs-on" "SIZE LIST" \
    "perl -pi -e 's/\"XLARGE\",\"MEDIUM_SPOT\"/\"XLARGE\"/ if /^\s*\(contains\(fromJSON/' .github/workflows/$wf"

  # The step's message forgets one size.
  case_ "$w-size-list-message" "SIZE LIST" \
    "perl -pi -e 's/XLARGE, MEDIUM_SPOT\./XLARGE./ if /::error::runner-sizes/' .github/workflows/$wf"
done

# A row naming one repository, rendered: the table names none, so refused.
case_ named-row "NAMED ROW" \
  "yq -i '.check.recipe.\"example/example\".build = \"LARGE\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

# The same in a fleet, whose runs-on still looks rows up by owner.
case_ named-fleet-row "NAMED ROW" \
  "yq -i '.\"renovate-fleet\".renovate.\"example/example\".renovate = \"LARGE\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

# An owner row where runs-on has no owner lookup: it could never answer.
case_ owner-row-in-check "NO OWNER ROW" \
  "yq -i '.check.recipe.\"example/*\".build = \"LARGE\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

# An owner row in a fleet passes.
case_ owner-row-in-fleet "" \
  "yq -i '.\"renovate-fleet\".renovate.\"example/*\".renovate = \"MEDIUM\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

[ "$fail" = 0 ] || { echo "runner-sizes cases: a guard did not hold (above)" >&2; exit 1; }
echo "runner-sizes cases passed"
