# ci-workflows

Shared reusable workflows for both Truvity organizations.

## Two rules

**1. Pin by commit SHA, never by tag or branch.** Every repository in both
organizations executes this code, so a compromise here reaches the whole
estate. Tags move; commit SHAs do not.

```yaml
uses: truvity/ci-workflows/.github/workflows/check.yaml@<40-char-sha>
```

**2. Mechanism only.** Account ids, role ARNs, registry hostnames, bucket
names, cluster names and internal DNS are **caller inputs or org
variables** — never content here. This repository is public, and public
history cannot be unpublished. `hack/leak-canary.sh` enforces it in CI.

## Why public

A private repository's reusable workflows cannot be called across an
organization boundary, and *internal* visibility needs an Enterprise plan
neither organization has. Public is therefore what lets `trust-form`
consume these directly — no mirror repository, no sync job, no drift
check. It is safe because of rule 2.

## check.yaml

Runs a repository's own Justfile recipes as **parallel jobs**, one per
recipe, each reported under its own name.

```yaml
jobs:
  check:
    uses: truvity/ci-workflows/.github/workflows/check.yaml@<sha>
    with:
      recipes: '["build","test","lint","vuln"]'
```

On an ARC runner, pass the scale-set label and the ARC flow:

```yaml
    with:
      recipes: '["build","test","lint","drift-check"]'
      runner: ${{ vars.CI_RUNNER_LABEL }}
      execution: arc
```

The recipes must exist in the caller's Justfile — they already do across
the estate; CI was simply collapsing them into one `just check`.

**Cost:** N recipes means N runners. Hosted minutes are free on public
repositories, so fan out freely there. On ARC one runner is currently one
node, so keep the list short until density work lands.
