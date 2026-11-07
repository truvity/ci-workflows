#!/usr/bin/env bash
# templates/company/<kind>/ are copy-per-repo callers: a company
# repository copies one verbatim. They must stay what truvity/ci-actions'
# caller-parity kits say they are (else the parity report calls every
# copy drifted), must trigger only on pull_request, and must carry the
# recipes the shared check.yaml calls. Each rule is also broken on a copy
# and expected to refuse, and an empty sweep is a refusal: a template
# directory that is gone must not read as "nothing to check".
#
# Linting (actionlint) and the pinned references (tagged-pins, the leak
# canary) are the repository's own gates and cover templates/ already.
#
#   hack/templates-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# The kits of ci-actions v3.11.0, by the commit of the tag. The commit is
# fixed on purpose (the kits are fetched over the network, from
# raw.githubusercontent.com, so a moving ref would change this check without
# a change here) and renovate does not move it. Bump it by hand with the
# templates: when the pin of check.yaml in the templates moves to a release,
# set this to the ci-actions commit whose kits that release's callers match.
kits=07baa32692f4ad11e5b1a37ceae5bcadb6faefc4
kinds="config delivery"

ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# Substance, as caller-parity reads it: comments, blank lines and the
# pinned ref of the shared workflow do not count.
substance() {
  sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d; s|(uses: truvity/ci-workflows/\.github/workflows/check\.yaml)@.*|\1@PIN|' "$1"
}

# verdict <caller file> <kit file> -> "same" or "differs"
verdict() { if diff -q <(substance "$1") <(substance "$2") >/dev/null; then echo same; else echo differs; fi; }

# case_ <name> <want: same|differs> <caller file> <kit file>
case_() {
  local got; got=$(verdict "$3" "$4")
  if [ "$got" = "$2" ]; then ok "$1: $2"; else bad "$1: $got, wanted $2"; fi
}

swept=0
for kind in $kinds; do
  d="$root/templates/company/$kind"
  wf="$d/.github/workflows/check.yaml"
  if [ ! -f "$wf" ]; then bad "$kind: no $wf"; continue; fi
  swept=$((swept + 1))

  kit="$tmp/kit-$kind.yaml"
  curl -fsS --retry 3 -o "$kit" \
    "https://raw.githubusercontent.com/truvity/ci-actions/$kits/caller-parity/kits/company-$kind-check.yaml" \
    || { bad "$kind: cannot read the kit at ci-actions $kits"; continue; }

  case_ "$kind: the template is the kit" same "$wf" "$kit"

  # Triggers: pull_request and nothing else. pull_request_target would run
  # the candidate with the base repository's token.
  on=$(yq -o=json '.on | keys' "$wf" | jq -c .)
  if [ "$on" = '["pull_request"]' ]; then ok "$kind: triggers on pull_request only"; else bad "$kind: triggers on $on"; fi

  # The recipe the shared workflow calls. It is a stub that fails loudly
  # until the chart gate exists: a stub that passes would read as a gate
  # that ran. The tenant bundle is validated by the shared workflow itself,
  # so a recipe of that name would be dead text that reads as the gate.
  for r in chart-gate; do
    if grep -qE "^$r:" "$d/Justfile"; then
      body=$(sed -n "/^$r:/,/^[^[:space:]]/p" "$d/Justfile")
      if grep -q 'exit 1' <<<"$body"; then ok "$kind: recipe $r is a stub that fails"; else bad "$kind: recipe $r does not fail"; fi
    else
      bad "$kind: Justfile has no recipe $r"
    fi
  done
  if grep -qE '^tenant-validate:' "$d/Justfile"; then bad "$kind: Justfile has a tenant-validate recipe, which nothing runs"; else ok "$kind: no tenant-validate recipe: the shared workflow validates the bundle"; fi

  # Mutations of the caller, each of which caller-parity would call drift.
  m() { local f="$tmp/$kind-$1.yaml"; cp "$wf" "$f"; shift; "$@" "$f"; echo "$f"; }
  case_ "$kind: another company-kind" differs \
    "$(m kind sed -i -E 's/^(\s*company-kind:).*/\1 platform/')" "$kit"
  case_ "$kind: pull_request_target" differs \
    "$(m target sed -i 's/^  pull_request:/  pull_request_target:/')" "$kit"
  case_ "$kind: a lenient fan-in" differs \
    "$(m lenient sed -i '/if: always()/d')" "$kit"
  case_ "$kind: a fan-in that lets a skip through" differs \
    "$(m skip sed -i 's/= "success"/!= "failure"/')" "$kit"
  case_ "$kind: tenant-inputs not from the variable" differs \
    "$(m var sed -i 's/vars.TENANT_INPUTS/vars.OTHER/')" "$kit"
done

# An empty sweep is not a pass.
if [ "$swept" = "$(wc -w <<<"$kinds")" ]; then ok "sweep: every kind ($kinds) was judged"; else bad "sweep: judged $swept of $(wc -w <<<"$kinds") kinds"; fi

echo
if [ "$fail" != 0 ]; then echo "templates-cases: FAILED"; exit 1; fi
echo "templates-cases: all passed"
