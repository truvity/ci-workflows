# ci-workflows

Shared reusable workflows for both Truvity organizations.

**Start here if you are setting up a repository:**
[docs/estate-lifecycle.md](docs/estate-lifecycle.md) — birth to
autopilot, cross-linking
[github-structure](https://github.com/truvity/github-structure)
(what a repo *is*) and
[ci-plane](https://github.com/truvity/ci-plane) (where CI *runs*, and
the artifact doctrine).

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

Preparing a repository so employees and CI resolve the same tools —
PATH order, tool ownership, and the `init_hook` substitution trap — is
**[docs/devbox.md](docs/devbox.md)**.

How a Go repository's toolchain triple (devbox `go`, `golangci-lint`'s
build Go, the `go.mod` directive) stays aligned — one owner, two
cadences, and every pitfall the rollout hit — is
**[docs/devbox-update.md](docs/devbox-update.md)**.

## check.yaml

Runs a repository's own Justfile recipes as **parallel jobs**, one per
recipe, each reported under its own name.

```yaml
permissions:
  contents: read     # always — checkout
  id-token: write    # ONLY if recipes reach AWS/k8s through zcbctl

jobs:
  recipes:
    uses: truvity/ci-workflows/.github/workflows/check.yaml@<sha>
    with:
      recipes: '["build","test","lint"]'
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
```

Those report as `recipes / build`, `recipes / test`, … — never as a bare
`recipes`. [Required checks](#required-checks) has the job your ruleset
should name instead.

**Declare the permissions block, always.** check.yaml carries no
permissions block of its own — a reusable workflow's block can only cap
the caller's grant, never widen it, so the decision belongs to the
caller. Grant `contents: read`; add `id-token: write` only when the
repository's recipes reach AWS or Kubernetes through zcbctl (the Zitadel
CI identity — see gitops `docs/guides/add-repo-to-ci.md`). Public
repositories omit it: fork PRs never receive an id-token, and nothing in
a public repository's recipes should want one. A caller with no block at
all hands its org-default token to every recipe.

The recipes must exist in the caller's Justfile — they already do across
the estate; CI was simply collapsing them into one `just check`.

**Cost:** N recipes means N runners. Hosted minutes are free on public
repositories, so fan out freely there. On ARC one runner is currently one
node, so keep the list short until density work lands.

## integration.yaml

Runs a gemaal-shaped project's integration suites, **one job per lane**:
build the lane's artifacts on the CI plane's remote builders, prove the
cluster identity, install into the CI tenant, run the suite, dump pod
logs on failure, uninstall.

```yaml
jobs:
  suites:
    uses: truvity/ci-workflows/.github/workflows/integration.yaml@<sha>
    permissions:
      contents: read
      id-token: write
    with:
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
      gemaal-namespace: ci-truvity-<repo>
      lanes: |
        [{"name": "…", "build": "…", "test": "…"}]
```

A lane's `build` and `test` are shell, so a caller that needs an
environment tweak puts it in the command itself.

## Required checks

**A reusable workflow cannot supply a required status context.** Every
job called through `uses:` reports as `<caller job> / <its own name>` —
`suites / integration-eudi-vp`, `check / lint`. A ruleset asking for a
bare `integration` or `check` will never see one.

It fails in the worst possible way: an unsatisfiable required context is
**pending**, not failing. Nothing goes red. `truvity/bar` wedged every
PR for a day this way (bar#706 → bar#713) with all six real checks green
— the fan-in job had been moved *into* this repository, where it could
only ever report as `integration / integration`.

So the fan-in belongs in the caller, next to the call:

```yaml
jobs:
  suites:
    uses: truvity/ci-workflows/.github/workflows/integration.yaml@<sha>
    # …

  # The name the ruleset requires. Gates on the whole call, so it
  # survives lanes and recipes being renamed.
  integration:
    needs: suites
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: '[ "${{ needs.suites.result }}" = "success" ]'
```

Strict `= "success"` means a **skipped** call fails the gate too. That is
the point: a fork PR gets no id-token, so its suites skip, and a skip
must not hand it a green required check for something that never ran.

## Contributing

Push access (branch → PR) is granted per team in gitops
`cfg/github.yaml`; the merge gate is the `check` context plus one
approval from someone other than the author. The repository is public,
so a fork PR works with no grant at all.

Running the shared self-hosted Renovate — the daemonless/npx execution
model, the entitlement silent-skip trap, and integrating repos whose
pin bumps regenerate derived files (postUpgradeTasks + allowed-commands
+ platformCommit) — is **[docs/renovate.md](docs/renovate.md)**.
