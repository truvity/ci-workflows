#!/usr/bin/env bash
# The refusals and the default job graph of the company inputs of
# check.yaml, each proved. A guard that cannot fail checks nothing, so every
# refusal here has a paired accepting case, and every rule of a guard is
# removed in turn and must turn at least one case red.
#
# The guards are the `run:` bodies of two steps in check.yaml; this runs
# them as written, with the environment the workflow gives them.
#
#   hack/company-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/check.yaml"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0
n=0

ok()  { echo "ok    $1"; }
bad() { echo "FAIL  $1"; fail=1; }

# script <job> <step id> -> the step's run body
script() { yq ".jobs.\"$1\".steps[] | select(.id == \"$2\") | .run" "$wf"; }

# run_guard <script file> VAR=value... -> prints output, returns its status
run_guard() {
  local s=$1; shift
  env -i PATH="$PATH" "$@" bash "$s" 2>&1
}

# case_ <name> <expect: pass|<fragment of the refusal>> <script file> VAR=value...
case_() {
  local name=$1 want=$2 s=$3 out rc=0; shift 3
  n=$((n + 1))
  out=$(run_guard "$s" "$@") || rc=$?
  if [ "$want" = pass ]; then
    if [ "$rc" = 0 ]; then ok "$name: passes"; else bad "$name: refused (rc=$rc), wanted a pass"; sed 's/^/      /' <<<"$out" | tail -3; fi
  else
    if [ "$rc" != 0 ] && grep -qF -- "$want" <<<"$out"; then ok "$name: refused ($want)"
    else bad "$name: rc=$rc, wanted a refusal naming '$want'"; sed 's/^/      /' <<<"$out" | tail -3; fi
  fi
}

# ---- the guard of both company jobs ------------------------------------
for job in company-boundary company-validate; do
  s="$tmp/$job-guard.sh"; script "$job" guard >"$s"
  [ -s "$s" ] || { bad "$job: no step with id guard"; continue; }

  guard_cases() { # <script> <label>
    local g=$1 l=$2
    local same="BASE_REPO=acme/ledger"
    case_ "$l kind config, pull request from the same repository" pass "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request HEAD_REPO=acme/ledger
    case_ "$l kind delivery, same repository" pass "$g" $same COMPANY_KIND=delivery EVENT_NAME=pull_request HEAD_REPO=acme/ledger
    case_ "$l same repository, other letter case" pass "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request HEAD_REPO=Acme/Ledger
    case_ "$l push has no head repository" pass "$g" $same COMPANY_KIND=config EVENT_NAME=push HEAD_REPO=
    case_ "$l merge group" pass "$g" $same COMPANY_KIND=delivery EVENT_NAME=merge_group HEAD_REPO=
    case_ "$l pull request from a fork" "company-fork" "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request HEAD_REPO=globex/ledger
    case_ "$l pull request from a fork of the same name" "company-fork" "$g" $same COMPANY_KIND=delivery EVENT_NAME=pull_request HEAD_REPO=globex/ledger
    case_ "$l pull request whose head repository is gone" "company-fork" "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request HEAD_REPO=
    case_ "$l head repository that only ends like the base" "company-fork" "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request HEAD_REPO=globex/acme/ledger
    case_ "$l pull_request_target, even from the same repository" "company-target" "$g" $same COMPANY_KIND=config EVENT_NAME=pull_request_target HEAD_REPO=acme/ledger
    case_ "$l unknown kind" "company-kind" "$g" $same COMPANY_KIND=platform EVENT_NAME=push HEAD_REPO=
    case_ "$l kind in capitals" "company-kind" "$g" $same COMPANY_KIND=Config EVENT_NAME=push HEAD_REPO=
    case_ "$l kind with a trailing space" "company-kind" "$g" $same "COMPANY_KIND=config " EVENT_NAME=push HEAD_REPO=
    case_ "$l empty kind" "company-kind" "$g" $same COMPANY_KIND= EVENT_NAME=push HEAD_REPO=
  }
  guard_cases "$s" "$job:"

  # Mutation proof: each rule, removed, must turn a case red.
  for rule in kind target fork; do
    grep -q "# rule:$rule\$" "$s" || { bad "$job: the guard has no '# rule:$rule' line"; continue; }
    sed "/# rule:$rule\$/d" "$s" >"$tmp/$job-no-$rule.sh"
    before=$fail; fail=0
    quiet=$(guard_cases "$tmp/$job-no-$rule.sh" "$job/no-$rule:" 2>&1) || true
    red=$(grep -c '^FAIL' <<<"$quiet" || true)
    fail=$before
    if [ "$red" -gt 0 ]; then ok "$job: removing rule $rule turns $red case(s) red"
    else bad "$job: removing rule $rule changed no case: the rule is not tested"; fi
  done
done

# ---- the inputs a requested recipe needs --------------------------------
s="$tmp/needs.sh"; script company-validate needs >"$s"
if [ -s "$s" ]; then
  needs_cases() {
    local g=$1 l=$2
    case_ "$l nothing requested" pass "$g" TENANT_VALIDATE=false CHART_GATE=false TENANT_INPUTS= CHART_PROFILE=
    case_ "$l tenant-validate with a pinned reference" pass "$g" TENANT_VALIDATE=true CHART_GATE=false TENANT_INPUTS=registry.example/acme/tenant@sha256:abc CHART_PROFILE=
    case_ "$l chart-gate with a profile" pass "$g" TENANT_VALIDATE=false CHART_GATE=true TENANT_INPUTS= CHART_PROFILE=aws:acme:charts-read
    case_ "$l tenant-validate without tenant-inputs" "tenant-inputs" "$g" TENANT_VALIDATE=true CHART_GATE=false TENANT_INPUTS= CHART_PROFILE=
    case_ "$l chart-gate without chart-profile" "chart-profile" "$g" TENANT_VALIDATE=false CHART_GATE=true TENANT_INPUTS= CHART_PROFILE=
  }
  needs_cases "$s" "needs:"
  for rule in tenant chart; do
    grep -q "# rule:$rule\$" "$s" || { bad "needs: no '# rule:$rule' line"; continue; }
    sed "/# rule:$rule\$/d" "$s" >"$tmp/needs-no-$rule.sh"
    before=$fail; fail=0
    quiet=$(needs_cases "$tmp/needs-no-$rule.sh" "needs/no-$rule:" 2>&1) || true
    red=$(grep -c '^FAIL' <<<"$quiet" || true)
    fail=$before
    if [ "$red" -gt 0 ]; then ok "needs: removing rule $rule turns $red case(s) red"
    else bad "needs: removing rule $rule changed no case: the rule is not tested"; fi
  done
else
  bad "company-validate: no step with id needs"
fi

# ---- the wiring the scripts depend on ----------------------------------
expect_env() { # job step var expression
  local got; got=$(yq ".jobs.\"$1\".steps[] | select(.id == \"$2\") | .env.\"$3\"" "$wf")
  if [ "$got" = "$4" ]; then ok "$1/$2: $3 is $4"; else bad "$1/$2: $3 is '$got', wanted '$4'"; fi
}
for job in company-boundary company-validate; do
  expect_env $job guard COMPANY_KIND '${{ inputs.company-kind }}'
  expect_env $job guard EVENT_NAME '${{ github.event_name }}'
  expect_env $job guard HEAD_REPO '${{ github.event.pull_request.head.repo.full_name }}'
  expect_env $job guard BASE_REPO '${{ github.repository }}'
  first=$(yq ".jobs.\"$job\".steps[0].id" "$wf")
  if [ "$first" = guard ]; then ok "$job: the guard is the first step"; else bad "$job: the first step is '$first', not the guard"; fi
  gate=$(yq ".jobs.\"$job\".\"if\"" "$wf")
  case "$gate" in
    "\${{ inputs.company-kind != '' && "*) ok "$job: runs only when company-kind is set" ;;
    *) bad "$job: its if does not start with the company-kind gate: $gate" ;;
  esac
done
expect_env company-validate needs TENANT_VALIDATE '${{ inputs.tenant-validate }}'
expect_env company-validate needs CHART_GATE '${{ inputs.chart-gate }}'
expect_env company-validate needs TENANT_INPUTS '${{ inputs.tenant-inputs }}'
expect_env company-validate needs CHART_PROFILE '${{ inputs.chart-profile }}'

# The guard must be a step that fails the job, not one that skips it.
for job in company-boundary company-validate; do
  coe=$(yq ".jobs.\"$job\".steps[0].\"continue-on-error\" // false" "$wf")
  if [ "$coe" = false ]; then ok "$job: the guard cannot be waved through"; else bad "$job: the guard has continue-on-error"; fi
done

# ---- the default job graph ---------------------------------------------
# Against v6.2.0 (hack/job-graph.v6.2.0), with the one documented
# difference removed: `recipes` is optional now, so the recipe job also
# needs a non-empty list. Every other job must be skipped by a caller that
# passes no company-kind.
cur=$("$root/hack/job-graph.sh" "$wf")
want=$(cat "$root/hack/job-graph.v6.2.0")
old_rows=$(grep -E '^\["(runners|pins|policy-conformance|recipe)"' <<<"$cur")
old_rows=${old_rows//" && inputs.recipes != ''"/}
if [ "$old_rows" = "$want" ]; then ok "job graph: runners, pins, policy-conformance and recipe are v6.2.0's"
else
  bad "job graph: the existing jobs differ from v6.2.0"
  diff <(echo "$want") <(echo "$old_rows") | sed 's/^/      /' | head -10
fi
while IFS= read -r row; do
  id=$(jq -r '.[0]' <<<"$row")
  case "$id" in runners|pins|policy-conformance|recipe) continue ;; esac
  gate=$(jq -r '.[3]' <<<"$row")
  case "$gate" in
    "\${{ inputs.company-kind != '' && "*) ok "job graph: $id is skipped without company-kind" ;;
    *) bad "job graph: $id is not gated on company-kind: $gate" ;;
  esac
done <<<"$cur"

echo
if [ "$fail" != 0 ]; then echo "company-cases: FAILED ($n guard cases run)"; exit 1; fi
echo "company-cases: all passed ($n guard cases run)"
