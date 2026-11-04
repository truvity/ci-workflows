#!/usr/bin/env bash
# runner-sizes.yaml -> the rendered copies in the workflows' runs-on.
#
#   hack/runner-sizes.sh render   rewrite every rendered copy from the table
#   hack/runner-sizes.sh check    refuse a bad table, or a copy that differs
#   hack/runner-sizes.sh audit    look each named recipe and lane up in its
#                                 caller's workflows (needs a gh session that
#                                 can read those repositories; not in CI)
#
# An expression cannot read a file, so each job that resolves a size
# carries its own rows as a JSON literal:
#
#   fromJSON('{"#":"check/recipe","truvity/gitops:ci-verify":"LARGE",...}')
#
# The "#" key names the section (<workflow>/<job>) and is what `render`
# finds the literal by. A key is "<repository>:<name>"; "<owner>/*:<name>"
# is the row for every repository of one owner (only where the job's
# runs-on looks it up: the fleets), and "*:<name>" the row for every
# repository. No repository is ever named "#" or "*", so
# neither key can answer a lookup by accident.
#
# Rows for a named repository are DEPRECATED: a caller names its own sizes
# in the `runner-sizes` input of check.yaml and integration.yaml, which
# those jobs read before the literal. `check` refuses a new named row (the
# count may only fall), a job in CALLER_JOBS whose runs-on does not read
# the input first, and a "Runner size is a size" list that differs from
# SIZES. A later major release drops the named rows and ORGS with them.
set -euo pipefail

cd "$(dirname "$0")/.."

TABLE=runner-sizes.yaml
SIZES='XSMALL SMALL MEDIUM LARGE XLARGE MEDIUM_SPOT'
ORGS='truvity trust-form finttech'
# The named rows left when they were deprecated. Lower it as rows move to
# their callers' `runner-sizes`; never raise it.
NAMED_ROWS_MAX=38
# <workflow>/<job>=<matrix key>: the jobs that read the caller's
# `runner-sizes` input before the table.
CALLER_JOBS='check/recipe=matrix.recipe integration/suite=matrix.name'

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
      local org=${repo%%/*}
      if ! [[ "$repo" =~ ^[A-Za-z0-9-]+/([A-Za-z0-9._-]+|\*)$ ]] || [[ " $ORGS " != *" $org "* ]]; then
        echo "BAD REPO     $where: '$repo' is not <owner>/<name> or <owner>/* in one of: $ORGS"; fail=1
      elif [[ "$repo" == */\* ]] \
           && ! yq ".jobs.\"$job\".runs-on // \"\"" ".github/workflows/$wf.yaml" | grep -qF 'github.repository_owner'; then
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

  # Deprecated rows: the named ones may go, never come.
  local named
  named=$(named_rows)
  if [ "$named" -gt "$NAMED_ROWS_MAX" ]; then
    echo "NEW NAMED    $named rows name a repository, over NAMED_ROWS_MAX=$NAMED_ROWS_MAX: such rows are deprecated; the caller passes its own runner-sizes input instead"
    fail=1
  fi

  # The caller's input comes first, in the job that the table resolves.
  local pair key input want_list
  want_list=$(printf '"%s",' $SIZES); want_list="[${want_list%,}]"
  for pair in $CALLER_JOBS; do
    wf=${pair%%/*}; job=${pair#*/}; job=${job%%=*}; key=${pair#*=}
    local f=".github/workflows/$wf.yaml" ro
    input=$(yq ".on.workflow_call.inputs.\"runner-sizes\" | [.type, .default] | join(\" \")" "$f")
    [ "$input" = "string {}" ] \
      || { echo "NO INPUT     $wf: no string input runner-sizes with default '{}' (have: '$input')"; fail=1; }
    ro=$(yq ".jobs.\"$job\".runs-on // \"\"" "$f")
    # The caller's lookup, then the first literal: in that order.
    if ! tr -d ' \n' <<<"$ro" \
         | grep -qF "vars[format('CI_RUNNER_LABEL_{0}',fromJSON(inputs.runner-sizes||'{}')[$key]||fromJSON('{\"#\":\"$wf/$job\""; then
      echo "NOT CALLER   $wf/$job: runs-on does not read fromJSON(inputs.runner-sizes || '{}')[$key] before the table"; fail=1
    fi
    local have_list
    have_list=$(yq ".jobs.\"$job\".steps[] | select(.name == \"Runner size is a size\") | .if" "$f" \
      | tr -d ' \n' | grep -oE "fromJSON\('\[[^]]*\]'\)" | sed -E "s/^fromJSON\('//; s/'\)$//" || true)
    [ "$have_list" = "$want_list" ] \
      || { echo "SIZE LIST    $wf/$job: the 'Runner size is a size' step checks '${have_list:-nothing}', SIZES is '$want_list'"; fail=1; }
  done

  return $fail
}

# Rows that name one repository (not "*", not "<owner>/*").
named_rows() {
  jq '[.[][] | to_entries[] | select(.key != "*" and (.key | endswith("/*") | not)) | .value | length] | add // 0' <<<"$json"
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
    rows=$(jq "[.[][][] | length] | add" <<<"$json")
    echo "runner-sizes: $rows rows in $(sections | wc -l) sections, every size valid, every job present, every copy current"
    echo "runner-sizes: $(named_rows) of them name a repository (deprecated; at most $NAMED_ROWS_MAX)"
    ;;
  audit)
    command -v gh >/dev/null || die "gh is not on PATH"
    fail=0 checked=0
    while IFS=$'\t' read -r wf repo name; do
      dir="${TMPDIR:-/tmp}/runner-sizes-audit/${repo//\//__}"
      if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        gh api "repos/$repo/contents/.github/workflows" --jq '.[] | select(.type == "file") | .path' \
          | while read -r p; do
              gh api "repos/$repo/contents/$p" --jq .content | base64 -d > "$dir/$(basename "$p")"
            done
      fi
      if [ "$wf" = integration ]; then
        pat="\"name\"[[:space:]]*:[[:space:]]*\"$name\""
      else
        pat="(^|[^A-Za-z0-9_-])$name([^A-Za-z0-9_-]|$)"
      fi
      checked=$((checked + 1))
      if grep -qE "$pat" "$dir"/* 2>/dev/null; then
        printf 'ok        %-16s %-40s %s\n' "$wf" "$repo" "$name"
      else
        printf 'MISSING   %-16s %-40s %s  (no such recipe or lane in its workflows)\n' "$wf" "$repo" "$name"
        fail=1
      fi
    done < <(jq -r '
      to_entries[] | .key as $wf | .value[] | to_entries[]
      | select(.key != "*" and (.key | endswith("/*") | not)) | .key as $repo | .value | keys[]
      | [$wf, $repo, .] | @tsv' <<<"$json")
    [ "$checked" -gt 0 ] || die "nothing to audit: the table names no repository"
    [ "$fail" = 0 ] || die "a row names a recipe or lane its caller does not run"
    echo "runner-sizes audit: $checked named rows, each found in its caller"
    ;;
  *)
    die "usage: $0 render|check|audit"
    ;;
esac
