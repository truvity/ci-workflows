#!/usr/bin/env bash
# What `setup-devbox` writes into GITHUB_ENV for each cache shape.
#
# This composite is estate-wide: every repository in both organizations runs
# it, and it reaches them only when a pin moves, so a mistake here is
# discovered one repository at a time over days. The two cache branches write
# the environment the Go toolchain then obeys -- GOCACHEPROG names a program
# that must exist, and a wrong value fails at the first `go` invocation with a
# message about the toolchain rather than about this action.
#
# So the branches are EXECUTED here, against a stubbed environment, and the
# variable names they emit are compared with what each shape is supposed to
# produce. Reading the YAML is not enough: the bucket branch must keep
# behaving exactly as it did after a change that only meant to add a
# neighbour.
set -uo pipefail

# yq reads the step out of the action. A missing tool must be one clear line
# rather than six cases failing with "no step named ...", which reads like the
# action changed.
if ! command -v yq >/dev/null 2>&1; then
    echo "yq (mikefarah) is required: ubuntu-latest ships it, devbox provides yq-go"
    exit 1
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
action="$root/.github/actions/setup-devbox/action.yaml"

fail=0
checked=0

# The two steps' scripts, pulled out by name so a rename is a loud failure
# rather than a silently skipped case.
extract() {
    yq -r ".runs.steps[] | select(.name == \"$1\") | .run" "$action"
}

# names prints the variable names a run of the script emitted, sorted. Values
# are deliberately ignored: they carry random heredoc delimiters, and what
# must not drift is WHICH variables a shape sets.
#
# LC_ALL=C, because the order is compared as a string: in a UTF-8 locale
# `sort` ignores the underscore and puts GOCACHE_DIR before GOCACHEPROG,
# while the C locale does the opposite. Without this the harness passes on
# one machine and fails on the runner.
names() {
    grep -oE '^[A-Z_][A-Z0-9_]*<<|^[A-Z_][A-Z0-9_]*=' "$1" \
        | sed 's/<<$//; s/=$//' | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

run_case() {
    local label="$1" step="$2" want="$3"
    shift 3

    checked=$((checked + 1))

    local dir script env_file
    dir="$(mktemp -d)"
    script="$dir/step.sh"
    env_file="$dir/github_env"
    : > "$env_file"

    if ! extract "$step" > "$script"; then
        echo "FAIL [$label]: no step named \"$step\" in the action"
        fail=$((fail + 1))
        rm -rf "$dir"
        return
    fi

    if [ ! -s "$script" ]; then
        echo "FAIL [$label]: step \"$step\" has an empty run block"
        fail=$((fail + 1))
        rm -rf "$dir"
        return
    fi

    # A stub for the binary the server branch insists on. Its absence is its
    # own case below.
    mkdir -p "$dir/bin"
    printf '#!/bin/sh\nexit 0\n' > "$dir/bin/ci-cache"
    chmod +x "$dir/bin/ci-cache"

    local out
    out="$(env -i PATH="$dir/bin:/usr/bin:/bin" HOME="$dir" \
        GITHUB_ENV="$env_file" RUNNER_TEMP="$dir/tmp" "$@" \
        bash "$script" 2>&1)"
    local rc=$?

    if [ $rc -ne 0 ]; then
        echo "FAIL [$label]: the step exited $rc"
        echo "$out" | sed 's/^/    /' | tail -3
        fail=$((fail + 1))
        rm -rf "$dir"
        return
    fi

    local got
    got="$(names "$env_file")"

    if [ "$got" != "$want" ]; then
        echo "FAIL [$label]: GITHUB_ENV sets"
        echo "     got  $got"
        echo "     want $want"
        fail=$((fail + 1))
    fi

    rm -rf "$dir"
}

# The bucket shape, unchanged. This is the case that matters most: it is what
# every repository does today, and adding the server branch must not move it.
run_case "bucket only" "Wire the fleet caches" \
    "GOCACHEPROG GOCACHE_DIR GOCACHE_KEY_PREFIX GOCACHE_METRICS GOCACHE_S3_BUCKET GOCACHE_S3_REGION" \
    CACHE_BUCKET=b CACHE_REGION=r CACHE_ENDPOINT= CACHE_PATH_STYLE= CACHE_GOPROXY=

run_case "bucket + endpoint + path-style + goproxy" "Wire the fleet caches" \
    "GOCACHEPROG GOCACHE_DIR GOCACHE_KEY_PREFIX GOCACHE_METRICS GOCACHE_S3_BUCKET GOCACHE_S3_ENDPOINT_URL GOCACHE_S3_PATH_STYLE GOCACHE_S3_REGION GOPROXY" \
    CACHE_BUCKET=b CACHE_REGION=r CACHE_ENDPOINT=https://e CACHE_PATH_STYLE=true CACHE_GOPROXY=http://p

# The server shape. No bucket, region, endpoint or metrics: the agent talks to
# the server and the server owns the object store. A stray GOCACHE_S3_* here
# would send the runner at the bucket with an identity it is about to lose.
run_case "server only" "Wire the fleet caches (cache server)" \
    "GOCACHEPROG" \
    CACHE_SERVER=http://s:8080 CACHE_GOPROXY=

run_case "server + goproxy" "Wire the fleet caches (cache server)" \
    "GOCACHEPROG GOPROXY" \
    CACHE_SERVER=http://s:8080 CACHE_GOPROXY=http://p

# A GitHub-hosted runner gets NOTHING, and this is the case that a real run
# taught. gitops' security workflow passes no cache inputs on purpose; an org
# variable read inside the reusable workflow gave it one anyway, on a hosted
# runner, and the job failed on the refusal below. The refusal was right and
# the reach was wrong.
checked=$((checked + 1))
hosted_dir="$(mktemp -d)"
: > "$hosted_dir/github_env"
extract "Wire the fleet caches (cache server)" > "$hosted_dir/step.sh"
if ! env -i PATH="/usr/bin:/bin" HOME="$hosted_dir" GITHUB_ENV="$hosted_dir/github_env" \
       RUNNER_TEMP="$hosted_dir/tmp" RUNNER_ENVIRONMENT=github-hosted \
       CACHE_SERVER=http://s:8080 CACHE_GOPROXY= \
       bash "$hosted_dir/step.sh" >"$hosted_dir/out" 2>&1; then
    echo "FAIL [github-hosted]: the step failed; a hosted runner must be skipped, not refused"
    sed 's/^/    /' "$hosted_dir/out" | tail -2
    fail=$((fail + 1))
elif [ -s "$hosted_dir/github_env" ]; then
    echo "FAIL [github-hosted]: wrote GITHUB_ENV on a hosted runner"
    sed 's/^/    /' "$hosted_dir/github_env" | head -2
    fail=$((fail + 1))
fi
rm -rf "$hosted_dir"

# The server branch must refuse a SELF-HOSTED runner image that predates the
# binary, rather than leave GOCACHEPROG naming a program that is not there.
checked=$((checked + 1))
missing_dir="$(mktemp -d)"
: > "$missing_dir/github_env"
extract "Wire the fleet caches (cache server)" > "$missing_dir/step.sh"
if env -i PATH="/usr/bin:/bin" HOME="$missing_dir" GITHUB_ENV="$missing_dir/github_env" \
       RUNNER_TEMP="$missing_dir/tmp" RUNNER_ENVIRONMENT=self-hosted \
       CACHE_SERVER=http://s:8080 CACHE_GOPROXY= \
       bash "$missing_dir/step.sh" >"$missing_dir/out" 2>&1; then
    echo "FAIL [no ci-cache on PATH]: the step succeeded; it must refuse"
    fail=$((fail + 1))
elif ! grep -q "runner image too old" "$missing_dir/out"; then
    echo "FAIL [no ci-cache on PATH]: refused, but not with the image message"
    sed 's/^/    /' "$missing_dir/out" | tail -2
    fail=$((fail + 1))
elif [ -s "$missing_dir/github_env" ]; then
    echo "FAIL [no ci-cache on PATH]: refused but still wrote GITHUB_ENV"
    fail=$((fail + 1))
fi
rm -rf "$missing_dir"

# The two branches must be mutually exclusive. Both writing GOCACHEPROG would
# leave the last step in file order to win, which is not a decision anybody
# made.
checked=$((checked + 1))
bucket_if="$(yq -r '.runs.steps[] | select(.name == "Wire the fleet caches") | .if' "$action")"
if [[ "$bucket_if" != *"go-cache-server == ''"* ]]; then
    echo "FAIL [precedence]: the bucket step does not stand down for the server"
    echo "     its condition is: $bucket_if"
    fail=$((fail + 1))
fi

if [ "$checked" -eq 0 ]; then
    echo "NOTHING CHECKED — the harness found no cases, which is a failure of the harness"
    exit 1
fi

if [ "$fail" -ne 0 ]; then
    echo "$fail case(s) failed of $checked"
    exit 1
fi

echo "cache wiring holds ($checked cases checked)"
