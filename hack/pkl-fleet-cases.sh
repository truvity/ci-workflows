#!/usr/bin/env bash
# The one assertion about pkl-fleet.yaml that is about the workflow text and not
# a rule: setup-devbox reads the consumer's own tool config, so it must never be
# handed the App token, only the job's read-only one. (The steps' rules are the
# ci-actions `pkl-fleet` action's, tested there.)
#
#   hack/pkl-fleet-cases.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
wf="$root/.github/workflows/pkl-fleet.yaml"

n=$(grep -c 'ci-actions/setup-devbox@' "$wf" || true)
ok=$(awk '/ci-actions\/setup-devbox@/{on=1} on && /github-token:/{print; on=0}' "$wf" | grep -c 'github-token: \${{ github.token }}$' || true)
if [ "$n" -ge 1 ] && [ "$n" = "$ok" ]; then
  echo "ok    setup-devbox gets only github.token ($n use)"
else
  echo "FAIL  setup-devbox wiring: $n uses, $ok with github.token"
  exit 1
fi
echo "pkl-fleet cases passed"
