#!/usr/bin/env bash
# runner-sizes.yaml -> the rendered copies in the workflows' runs-on.
#
#   hack/runner-sizes.sh render   rewrite every rendered copy from the table
#   hack/runner-sizes.sh check    refuse a bad table, or a copy that differs
#
# An expression cannot read a file, so each job that resolves a size
# carries its own rows as a JSON literal:
#
#   fromJSON('{"#":"check/recipe","*:vuln":"MEDIUM",...}')
#
# The "#" key names the section (<workflow>/<job>) and is what `render`
# finds the literal by. A key is "*:<name>", the row for every repository,
# or "<owner>/*:<name>", the row for every repository of one owner (only
# where the job's runs-on looks it up: the fleets). No owner is ever named
# "#" or "*", so neither key can answer a lookup by accident.
#
# The table names no repository: a caller names its own sizes in the
# `runner-sizes` input of check.yaml, integration.yaml, renovate-fleet.yaml
# and parity-fleet.yaml, which those jobs read before the literal. `check`
# refuses a row that names one repository, an <owner>/* row whose owner is
# not in ORGS (a misspelt owner can never match github.repository_owner, so
# it would fall through to "*" unseen), a job in CALLER_JOBS whose runs-on
# does not read the input first, a "Runner size is a size" step that is
# missing or checks another entry, and a copy of the size list (in runs-on,
# in that step's `if` and in its message) that differs from SIZES.
set -euo pipefail

cd "$(dirname "$0")/.."

TABLE=runner-sizes.yaml
SIZES='XSMALL SMALL MEDIUM LARGE XLARGE MEDIUM_SPOT'
# The owners an <owner>/* row may name.
ORGS='truvity trust-form finttech'
# <workflow>/<job>=<key>[@<step job>]: the jobs that read the caller's
# `runner-sizes` input before the table, by <key> (a matrix key, or the
# job's one name quoted), and the job whose "Runner size is a size" step
# refuses a value that is not a size: the job itself, or <step job> (the
# fleets check once, in `discover`, instead of in every repository's job).
CALLER_JOBS="check/recipe=matrix.recipe integration/suite=matrix.name renovate-fleet/renovate='renovate'@discover parity-fleet/align='align'@discover"

die() { echo "runner-sizes: $*" >&2; exit 1; }

command -v yq >/dev/null || die "yq is not on PATH (devbox run -- hack/runner-sizes.sh ...)"
command -v jq >/dev/null || die "jq is not on PATH"

json=$(yq -o=json '.' "$TABLE")

# One line per section: <workflow> <job> <rendered literal>.
sections() {
  jq -r '
    to_entries[] | .key as $wf | .value | to_entries[] | .key as $job
    | ({"#": "\($wf)/\($job)"}
       + ([.value | to_entries[] | .key as $repo | .value | to_entries[]
           | {key: "\($repo):\(.key)", value: .value}] | from_entries))
    | "\($wf) \($job) \(tojson)"' <<<"$json" | LC_ALL=C sort
}

# Every literal a workflow file carries: <file> <section>.
literals() {
  grep -oE "fromJSON\('\{\"#\":\"[^\"]+\"" .github/workflows/*.yaml \
    | sed -E "s/:fromJSON\('\{\"#\":\"/ /; s/\"$//" | LC_ALL=C sort -u
}

validate() {
  local fail=0 wf job repo name size
  [ "$(jq -r 'type' <<<"$json")" = object ] || die "$TABLE is not a mapping"

  while IFS=$'\t' read -r wf job repo name size; do
    local where="$wf/$job $repo:$name"
    [ -f ".github/workflows/$wf.yaml" ] || { echo "NO WORKFLOW  $where: .github/workflows/$wf.yaml does not exist"; fail=1; continue; }
    if [ "$(yq ".jobs | has(\"$job\")" ".github/workflows/$wf.yaml")" != true ]; then
      echo "NO JOB       $where: $wf.yaml has no job '$job'"; fail=1
    fi
    case " $SIZES " in *" $size "*) ;; *) echo "BAD SIZE     $where: '$size' (one of: $SIZES)"; fail=1 ;; esac
    if [ "$repo" != '*' ]; then
      if [[ "$repo" =~ ^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$ ]]; then
        echo "NAMED ROW    $where: the table names no repository; the caller passes its own runner-sizes input instead"; fail=1
      elif ! [[ "$repo" =~ ^[A-Za-z0-9-]+/\*$ ]]; then
        echo "BAD REPO     $where: '$repo' is not \"*\" or <owner>/*"; fail=1
      elif [[ " $ORGS " != *" ${repo%/\*} "* ]]; then
        echo "BAD OWNER    $where: '${repo%/\*}' is not one of: $ORGS"; fail=1
      elif ! yq ".jobs.\"$job\".runs-on // \"\"" ".github/workflows/$wf.yaml" | grep -qF 'github.repository_owner'; then
        echo "NO OWNER ROW $where: jobs.$job.runs-on has no <owner>/* lookup (github.repository_owner)"; fail=1
      fi
    fi
    if ! [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "BAD NAME     $where: '$name' (letters, digits, '.', '_' and '-' only)"; fail=1
    fi
  done < <(jq -r '
    to_entries[] | .key as $wf
    | if (.value | type) != "object" then error("\($wf): not a mapping") else . end
    | .value | to_entries[] | .key as $job
    | .value | to_entries[] | .key as $repo
    | .value | to_entries[] | [$wf, $job, $repo, .key, (.value | tostring)] | @tsv' <<<"$json")

  # A section with no literal resolves nothing; a literal with no section
  # is a job reading rows nobody can edit.
  local want have
  want=$(sections | awk '{print ".github/workflows/" $1 ".yaml " $1 "/" $2}')
  have=$(literals)
  while read -r f s; do
    [ -n "$f" ] || continue
    grep -qxF "$f $s" <<<"$have" || { echo "NOT RESOLVED $s: $f has no literal for it (render it into the job's runs-on)"; fail=1; }
  done <<<"$want"
  while read -r f s; do
    [ -n "$f" ] || continue
    grep -qxF "$f $s" <<<"$want" || { echo "NO SECTION   $f carries a literal for '$s', which $TABLE does not have"; fail=1; }
  done <<<"$have"

  # The literal sits in THAT job's runs-on, not just somewhere in the file.
  while read -r wf job _; do
    local ro
    ro=$(yq ".jobs.\"$job\".runs-on // \"\"" ".github/workflows/$wf.yaml" 2>/dev/null || true)
    grep -qF "fromJSON('{\"#\":\"$wf/$job\"" <<<"$ro" \
      || { echo "NOT IN JOB   $wf/$job: the literal is not in jobs.$job.runs-on"; fail=1; }
  done < <(sections)

  # The caller's input comes first, in the job that the table resolves,
  # and only when it is a size.
  local pair key input want_list want_text c step_job
  want_list=$(printf '"%s",' $SIZES); want_list="[${want_list%,}]"
  want_text="a size is one of $(sed 's/ /, /g' <<<"$SIZES")."
  for pair in $CALLER_JOBS; do
    wf=${pair%%/*}; job=${pair#*/}; job=${job%%=*}; key=${pair#*=}
    step_job=$job
    case "$key" in *@*) step_job=${key#*@}; key=${key%@*} ;; esac
    local f=".github/workflows/$wf.yaml" ro step
    input=$(yq ".on.workflow_call.inputs.\"runner-sizes\" | [.type, .default] | join(\" \")" "$f")
    [ "$input" = "string {}" ] \
      || { echo "NO INPUT     $wf: no string input runner-sizes with default '{}' (have: '$input')"; fail=1; }
    ro=$(yq ".jobs.\"$job\".runs-on // \"\"" "$f" | tr -d ' \n')
    step=$(yq ".jobs.\"$step_job\".steps[] | select(.name == \"Runner size is a size\")" "$f")
    [ -n "$step" ] \
      || { echo "NO STEP      $wf/$job: jobs.$step_job has no 'Runner size is a size' step"; fail=1; }
    c="fromJSON(inputs.runner-sizes||'{}')[$key]"
    # The caller's lookup, gated on the size list, then the first literal:
    # in that order. The list itself is SIZE LIST's business, so any list
    # matches here.
    if ! sed -E "s/fromJSON\('\[[^]]*\]'\)/SIZES/g" <<<"$ro" \
         | grep -qF "vars[format('CI_RUNNER_LABEL_{0}',(contains(SIZES,$c)&&$c)||fromJSON('{\"#\":\"$wf/$job\""; then
      echo "NOT CALLER   $wf/$job: runs-on does not read fromJSON(inputs.runner-sizes || '{}')[$key], only when it is a size, before the table"; fail=1
    fi
    # Every copy of the list: one in runs-on, one in the step's `if`, and
    # the step's message. The step reads the same entry runs-on reads.
    yq '.if // ""' <<<"$step" | tr -d ' \n' | grep -qF "toJSON($c)!='null'&&!contains(" \
      || { echo "NOT CALLER   $wf/$job: the 'Runner size is a size' step in jobs.$step_job does not check fromJSON(inputs.runner-sizes || '{}')[$key]"; fail=1; }
    local where have_list
    for where in runs-on if; do
      if [ "$where" = runs-on ]; then have_list=$ro
      else have_list=$(yq '.if // ""' <<<"$step" | tr -d ' \n'); fi
      have_list=$(grep -oE "fromJSON\('\[[^]]*\]'\)" <<<"$have_list" | sed -E "s/^fromJSON\('//; s/'\)$//" || true)
      [ "$have_list" = "$want_list" ] \
        || { echo "SIZE LIST    $wf/$job: the list in $where is '${have_list:-nothing}', SIZES is '$want_list'"; fail=1; }
    done
    yq '.run // ""' <<<"$step" | grep -qF "$want_text" \
      || { echo "SIZE LIST    $wf/$job: the 'Runner size is a size' step's message does not say '$want_text'"; fail=1; }
  done

  return $fail
}

render() {
  local wf job lit f
  while read -r wf job lit; do
    f=".github/workflows/$wf.yaml"
    [ -f "$f" ] || continue
    M="$wf/$job" J="$lit" perl -pi -e \
      's/fromJSON\(\x27\{"#":"\Q$ENV{M}\E"[^\x27]*\x27\)/fromJSON(\x27$ENV{J}\x27)/g' "$f"
  done < <(sections)
}

case "${1:-check}" in
  render)
    validate >/dev/null || true
    render
    echo "runner-sizes: rendered $(sections | wc -l) sections into the workflows"
    ;;
  check)
    fail=0
    validate || fail=1
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    cp -r .github "$tmp/"
    render
    if ! diff -ru "$tmp/.github" .github; then
      echo "STALE        a rendered copy differs from $TABLE: run 'just runner-sizes' and commit the result"
      rm -rf .github && cp -r "$tmp/.github" .github
      fail=1
    fi
    [ "$fail" = 0 ] || die "the table and its copies disagree (above)"
    rows=$(jq "[.[][][] | length] | add // 0" <<<"$json")
    echo "runner-sizes: $rows rows in $(sections | wc -l) sections, no repository named, every size valid, every job present, every copy current"
    ;;
  *)
    die "usage: $0 render|check"
    ;;
esac
