#!/usr/bin/env bash
# One line per job of a workflow file: id, name, needs, if, as JSON. The
# job graph is what a caller's required checks and fan-in see, so it is
# what must not move for a caller that opts into nothing.
#
#   hack/job-graph.sh [workflow-file]     default .github/workflows/check.yaml
set -euo pipefail
f=${1:-.github/workflows/check.yaml}
yq -o=json '.' "$f" | jq -c '
  .jobs | to_entries | sort_by(.key)[]
  | [.key, (.value.name // .key),
     ((.value.needs // []) | if type == "array" then . else [.] end),
     (.value["if"] // "")]'
