#!/usr/bin/env bash
# The tenant validator step of check.yaml's company-validate job, proved:
# it runs the real truvity/policy validator, at the version the workflow
# pins, and fails on a bad bundle. A gate that cannot fail checks nothing,
# so every refusal has an accepting case beside it, and the call to the
# validator and each rule of the step are removed in turn and must turn a
# case red.
#
# What it runs is the workflow's own text: the install step's `run:` body
# builds the validator from the pinned module (this needs `go` and the
# network, as the job does), and the validate step's body runs against the
# bundles in hack/testdata/tenant, with the environment the workflow gives
# it. What it cannot run is GitHub parsing the call: company-cases.sh holds
# the wiring around these steps, and the fetch of the inputs artifact, the
# chart login and a company's own repository are not reachable from here.
#
#   hack/tenant-validate-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/check.yaml"
fx="$root/hack/testdata/tenant"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
n=0

ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# script <job> <step id> -> the step's run body
script() { yq ".jobs.\"$1\".steps[] | select(.id == \"$2\") | .run" "$wf"; }
# step_field <job> <step id> <yq path under the step>
step_field() { yq ".jobs.\"$1\".steps[] | select(.id == \"$2\") | $3" "$wf"; }

command -v go >/dev/null || { bad "go is not on PATH: the validator cannot be built, so nothing here can be proved"; echo "tenant-validate-cases: FAILED"; exit 1; }

# ---- the pin ------------------------------------------------------------
version=$(step_field company-validate validator '.env.POLICY_VERSION')
if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then ok "the validator is pinned to truvity/policy v$version"; else bad "POLICY_VERSION is '$version', not a plain version"; fi
# The annotation renovate's custom manager reads sits on the line above.
if grep -qE '^ +# renovate: datasource=github-releases depName=truvity/policy$' "$wf" \
   && grep -A1 'depName=truvity/policy$' "$wf" | grep -qE '^ +POLICY_VERSION: "[0-9.]+"$'; then
  ok "the pin carries the renovate annotation"
else bad "POLICY_VERSION has no renovate annotation directly above it"; fi

# ---- the wiring that the step bodies depend on --------------------------
for id in validator bundle; do
  got=$(step_field company-validate "$id" '.if')
  if [ "$got" = "inputs.tenant-validate" ]; then ok "step $id runs only when tenant-validate is on"; else bad "step $id has if '$got'"; fi
done
got=$(yq '.jobs."company-validate".steps[] | select(.uses | test("^actions/setup-go@")) | .if' "$wf")
if [ "$got" = "inputs.tenant-validate" ]; then ok "setup-go runs only when tenant-validate is on"; else bad "setup-go has if '$got'"; fi
got=$(yq '.jobs."company-validate".steps[] | select(.uses | test("^truvity/ci-actions/setup-devbox@")) | .if' "$wf")
if [ "$got" = "inputs.chart-gate" ]; then ok "devbox is set up for the chart gate alone"; else bad "setup-devbox has if '$got'"; fi
if yq '.jobs."company-validate".steps[].with.recipe' "$wf" | grep -qx tenant-validate; then
  bad "a recipe named tenant-validate is still run: the company's stub would stand in for the validator"
else ok "no recipe named tenant-validate is run"; fi
order=$(yq '.jobs."company-validate".steps[] | .id // (.uses | sub("@.*";""))' "$wf" | tr '\n' ' ')
for pair in "validator bundle" "bundle truvity/ci-actions/chart-auth" "truvity/ci-actions/recipe coverage"; do
  set -- $pair
  a=${order%%"$1 "*}; b=${order%%"$2 "*}
  if [[ "$order" == *"$1 "* && "$order" == *"$2 "* && ${#a} -lt ${#b} ]]; then ok "step order: $1 before $2"; else bad "step order: $1 is not before $2 ($order)"; fi
done
unset -v a b

# ---- build the real validator, as the install step does -----------------
rt="$tmp/runner-temp"; mkdir -p "$rt"
s="$tmp/install.sh"; script company-validate validator >"$s"
n=$((n + 1))
if out=$(env RUNNER_TEMP="$rt" POLICY_VERSION="$version" bash "$s" 2>&1) && [ -x "$rt/tenant-validate/tenant-validate" ]; then
  ok "install: builds truvity/policy v$version into \$RUNNER_TEMP"
else bad "install: the pinned validator did not build"; tail -5 <<<"$out" | sed 's/^/      /'; fi

# ---- the validate step --------------------------------------------------
b="$tmp/bundle.sh"; script company-validate bundle >"$b"
[ -s "$b" ] || { bad "company-validate has no step with id bundle"; echo "tenant-validate-cases: FAILED"; exit 1; }

# repo <fixture|-> [link] -> a throwaway repository with that bundle as tenant/
repo() {
  local r; r=$(mktemp -d -p "$tmp"); mkdir -p "$r/.git"
  case "$1" in
    -) ;;
    link) mkdir "$r/elsewhere"; cp "$fx"/valid-acme/* "$r/elsewhere/"; ln -s elsewhere "$r/tenant" ;;
    *) cp -r "$fx/$1" "$r/tenant" ;;
  esac
  echo "$r"
}

# case_ <script> <name> <fixture> <kind> <expect: pass|<fragment>> [RUNNER_TEMP]
case_() {
  local sc=$1 name=$2 fxn=$3 kind=$4 want=$5 rtd=${6:-$rt} r out rc=0
  n=$((n + 1))
  r=$(repo "$fxn")
  out=$(cd "$r" && env -i PATH="$PATH" RUNNER_TEMP="$rtd" COMPANY_KIND="$kind" bash "$sc" 2>&1) || rc=$?
  if [ "$want" = pass ]; then
    if [ "$rc" = 0 ]; then ok "$name: passes"; else bad "$name: refused (rc=$rc), wanted a pass"; tail -3 <<<"$out" | sed 's/^/      /'; fi
  else
    if [ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out"; then ok "$name: refused ($want)"
    else bad "$name: rc=$rc, wanted a refusal naming '$want'"; tail -3 <<<"$out" | sed 's/^/      /'; fi
  fi
  LAST_OUT=$out
}

bundle_cases() { # <script> <label>
  local g=$1 l=$2
  case_ "$g" "$l acme bundle" valid-acme config pass
  case_ "$g" "$l globex bundle" valid-globex config pass
  case_ "$g" "$l unknown field" refused-unknown-field config "unknown-field"
  case_ "$g" "$l grant with no reason" refused-missing-reason config "missing-reason"
  case_ "$g" "$l the refusal says who refused" refused-unknown-field config "refused by truvity/policy"
  case_ "$g" "$l no tenant/ directory" - config "no tenant/ directory"
  case_ "$g" "$l tenant/ is a link" link config "no tenant/ directory"
  case_ "$g" "$l delivery repository" valid-acme delivery "holds no tenant/ bundle"
  case_ "$g" "$l validator not installed" valid-acme config "not installed" "$tmp/empty-runner-temp"
}
mkdir -p "$tmp/empty-runner-temp"
bundle_cases "$b" "bundle:"

# What an accepted bundle prints: the company and a real pin, and what was
# not checked.
case_ "$b" "bundle: output of an accepted bundle" valid-acme config pass
if grep -qE 'accepted: company and pin: acme sha256:[0-9a-f]{64}$' <<<"$LAST_OUT"; then ok "bundle: prints the company and its pin"; else bad "bundle: no 'acme sha256:<hex>' line"; fi
if grep -q 'NOT checked: the registration check' <<<"$LAST_OUT"; then ok "bundle: says the registration check did not run"; else bad "bundle: a pass does not say what it did not check"; fi

# Mutation proof. The step with the call to the validator replaced by one
# that accepts everything must let the bad bundles through, which turns
# their cases red; so must each rule, removed.
mutant() { # <name> <script file>
  local before=$fail red quiet
  fail=0
  quiet=$(bundle_cases "$2" "bundle/$1:" 2>&1) || true
  red=$(grep -c '^FAIL' <<<"$quiet" || true)
  fail=$before
  if [ "$red" -gt 0 ]; then ok "bundle: $1 turns $red case(s) red"
  else bad "bundle: $1 changed no case: it is not tested"; fi
}
grep -q 'pin=$("$validator" tenant) || rc=$?' "$b" || bad "bundle: the call to the validator is not the line this harness mutates"
sed 's|pin=$("$validator" tenant) \|\| rc=$?|pin=$(echo "acme sha256:0") \|\| rc=$?|' "$b" >"$tmp/no-run.sh"
mutant "not running the validator" "$tmp/no-run.sh"
for rule in kind dir exit; do
  grep -q "# rule:$rule\$" "$b" || { bad "bundle: no '# rule:$rule' line"; continue; }
  sed "/# rule:$rule\$/d" "$b" >"$tmp/no-$rule.sh"
  mutant "removing rule $rule" "$tmp/no-$rule.sh"
done

# ---- what a green run says it did not validate --------------------------
c="$tmp/coverage.sh"; script company-validate coverage >"$c"
[ -s "$c" ] || { bad "company-validate has no step with id coverage"; echo "tenant-validate-cases: FAILED"; exit 1; }
for kind in config delivery; do
  for tv in true false; do
    for cg in true false; do
      n=$((n + 1))
      out=$(env -i PATH="$PATH" COMPANY_KIND=$kind TENANT_VALIDATE=$tv CHART_GATE=$cg bash "$c" 2>&1) || { bad "coverage $kind tv=$tv cg=$cg: the step failed"; continue; }
      lines=$(grep -c '^not validated: ' <<<"$out" || true)
      # One statement each for the bundle (off: none validated; on: no
      # registration check) and the charts (off: none gated; on: the
      # company's recipe only), and one more for a delivery repository.
      want=2
      [ "$kind" != delivery ] || want=3
      if [ "$lines" = "$want" ]; then ok "coverage $kind tenant-validate=$tv chart-gate=$cg: $lines statement(s) of what was not validated"
      else bad "coverage $kind tenant-validate=$tv chart-gate=$cg: $lines statement(s), wanted $want"; echo "$out" | sed 's/^/      /'; fi
      case $tv in
        true) grep -q 'not checked against the platform' <<<"$out" || bad "coverage $kind tv=$tv cg=$cg: no mention of the registration check" ;;
        false) grep -q 'tenant-validate is off: no tenant bundle was validated' <<<"$out" || bad "coverage $kind tv=$tv cg=$cg: an off validator is not said to validate nothing" ;;
      esac
      case $cg in
        true) grep -q "ran the company's own recipe" <<<"$out" || bad "coverage $kind tv=$tv cg=$cg: the chart gate's coverage is not stated" ;;
        false) grep -q 'chart-gate is off: no chart was gated' <<<"$out" || bad "coverage $kind tv=$tv cg=$cg: an off chart gate is not said to gate nothing" ;;
      esac
      [ "$kind" != delivery ] || grep -q 'pins/ and values/' <<<"$out" || bad "coverage delivery tv=$tv cg=$cg: pins/ and values/ are not said to be unvalidated"
    done
  done
done

echo
if [ "$fail" != 0 ]; then echo "tenant-validate-cases: FAILED ($n cases run)"; exit 1; fi
echo "tenant-validate-cases: all passed ($n cases run)"
