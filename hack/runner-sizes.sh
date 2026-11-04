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
# those jobs read before the literal. `check` refuses a named row that is
# not in NAMED_FROZEN (and a line there whose row is gone), a job in
# CALLER_JOBS whose runs-on does not read the input first, and a copy of
# the size list (in runs-on, in the "Runner size is a size" step's `if`
# and in its message) that differs from SIZES. A later major release drops
# the named rows, NAMED_FROZEN and ORGS with them.
set -euo pipefail

cd "$(dirname "$0")/.."

TABLE=runner-sizes.yaml
SIZES='XSMALL SMALL MEDIUM LARGE XLARGE MEDIUM_SPOT'
ORGS='truvity trust-form finttech'
# The named rows left when they were deprecated, one per line. A row may
# leave (from both files); none may join.
NAMED_FROZEN=hack/runner-sizes-named.txt
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

  # Deprecated rows: the named ones may go, never come. Compared as keys,
  # not counted, so a row swapped for another is refused too.
  local frozen row
  [ -f "$NAMED_FROZEN" ] || die "$NAMED_FROZEN does not exist"
  frozen=$(grep -v '^#' "$NAMED_FROZEN" | LC_ALL=C sort)
  while read -r row; do
    [ -n "$row" ] || continue
    echo "NEW NAMED    $row: a row naming a repository is deprecated and not in $NAMED_FROZEN; the caller passes its own runner-sizes input instead"
    fail=1
  done < <(LC_ALL=C comm -23 <(named_keys) <(cat <<<"$frozen"))
  while read -r row; do
    [ -n "$row" ] || continue
    echo "GONE NAMED   $row: in $NAMED_FROZEN but not in $TABLE; drop the line too, so the row cannot come back"
    fail=1
  done < <(LC_ALL=C comm -13 <(named_keys) <(cat <<<"$frozen"))

  # The caller's input comes first, in the job that the table resolves,
  # and only when it is a size.
  local pair key input want_list want_text c
  want_list=$(printf '"%s",' $SIZES); want_list="[${want_list%,}]"
  want_text="a size is one of $(sed 's/ /, /g' <<<"$SIZES")."
  for pair in $CALLER_JOBS; do
    wf=${pair%%/*}; job=${pair#*/}; job=${job%%=*}; key=${pair#*=}
    local f=".github/workflows/$wf.yaml" ro step
    input=$(yq ".on.workflow_call.inputs.\"runner-sizes\" | [.type, .default] | join(\" \")" "$f")
    [ "$input" = "string {}" ] \
      || { echo "NO INPUT     $wf: no string input runner-sizes with default '{}' (have: '$input')"; fail=1; }
    ro=$(yq ".jobs.\"$job\".runs-on // \"\"" "$f" | tr -d ' \n')
    step=$(yq ".jobs.\"$job\".steps[] | select(.name == \"Runner size is a size\")" "$f")
    c="fromJSON(inputs.runner-sizes||'{}')[$key]"
    # The caller's lookup, gated on the size list, then the first literal:
    # in that order. The list itself is SIZE LIST's business, so any list
    # matches here.
    if ! sed -E "s/fromJSON\('\[[^]]*\]'\)/SIZES/g" <<<"$ro" \
         | grep -qF "vars[format('CI_RUNNER_LABEL_{0}',(contains(SIZES,$c)&&$c)||fromJSON('{\"#\":\"$wf/$job\""; then
      echo "NOT CALLER   $wf/$job: runs-on does not read fromJSON(inputs.runner-sizes || '{}')[$key], only when it is a size, before the table"; fail=1
    fi
    # Every copy of the list: one in runs-on, one in the step's `if`, and
    # the step's message.
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

# Rows that name one repository (not "*", not "<owner>/*"), one per line:
# <workflow>/<job> <repository>:<name>, sorted.
named_keys() {
  jq -r '
    to_entries[] | .key as $wf | .value | to_entries[] | .key as $job
    | .value | to_entries[] | select(.key != "*" and (.key | endswith("/*") | not))
    | .key as $repo | .value | keys[] | "\($wf)/\($job) \($repo):\(.)"' <<<"$json" | LC_ALL=C sort
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
    echo "runner-sizes: $(named_keys | wc -l) of them name a repository (deprecated; each frozen in $NAMED_FROZEN)"
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
