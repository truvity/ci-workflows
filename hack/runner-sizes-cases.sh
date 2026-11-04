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

# check.yaml's recipe job stops reading the caller's input first.
case_ no-caller-lookup "NOT CALLER" \
  "perl -0pi -e 's/fromJSON\(inputs\.runner-sizes \|\| \x27\{\}\x27\)\[matrix\.recipe\]\n\s*\|\| //' .github/workflows/check.yaml"

# The input's default stops being the empty object, so callers that pass
# nothing would no longer keep today's sizes.
case_ input-default "NO INPUT" \
  "yq -i '.on.workflow_call.inputs.\"runner-sizes\".default = \"[]\"' .github/workflows/integration.yaml"

# The step that refuses a bad size forgets one size.
case_ size-list "SIZE LIST" \
  "perl -pi -e 's/\"XLARGE\",\"MEDIUM_SPOT\"/\"XLARGE\"/ if /contains\(fromJSON/' .github/workflows/integration.yaml"

# A new row naming a repository (in the first organisation the script
# accepts), rendered: deprecated, so refused.
org=$(sed -n "s/^ORGS='\([^ ']*\).*/\1/p" "$root/hack/runner-sizes.sh")
case_ new-named-row "NEW NAMED" \
  "yq -i '.check.recipe.\"$org/example\".build = \"LARGE\"' runner-sizes.yaml && ./hack/runner-sizes.sh render >/dev/null"

[ "$fail" = 0 ] || { echo "runner-sizes cases: a guard did not hold (above)" >&2; exit 1; }
echo "runner-sizes cases passed"
