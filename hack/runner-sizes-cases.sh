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

# A new row naming a repository (in the first organisation the script
# accepts), rendered: deprecated, so refused.
org=$(sed -n "s/^ORGS='\([^ ']*\).*/\1/p" "$root/hack/runner-sizes.sh")
case_ new-named-row "NEW NAMED" \
  "yq -i '.check.recipe.\"$org/example\".build = \"LARGE\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

# One named row swapped for another: the count stays, the keys do not.
first=$(grep -v '^#' "$root/hack/runner-sizes-named.txt" | grep '^check/recipe ' | head -1)
frepo=${first#* }; frepo=${frepo%%:*}; fname=${first##*:}
case_ swapped-named-row "NEW NAMED" \
  "yq -i 'del(.check.recipe.\"$frepo\".\"$fname\") | .check.recipe.\"$org/example\".build = \"LARGE\"' runner-sizes.yaml && sed -i '\\|^$first\$|d' hack/runner-sizes-named.txt && ./hack/runner-sizes.sh render >/dev/null"

# A named row moved to its caller, its frozen line left behind: the row
# could come back unnoticed.
case_ stale-frozen-line "GONE NAMED" \
  "yq -i 'del(.check.recipe.\"$frepo\".\"$fname\")' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

# The same move with the line dropped too passes.
case_ moved-named-row "" \
  "yq -i 'del(.check.recipe.\"$frepo\".\"$fname\")' runner-sizes.yaml && sed -i '\\|^$first\$|d' hack/runner-sizes-named.txt && ./hack/runner-sizes.sh render >/dev/null"

[ "$fail" = 0 ] || { echo "runner-sizes cases: a guard did not hold (above)" >&2; exit 1; }
echo "runner-sizes cases passed"
