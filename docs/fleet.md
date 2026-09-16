# Fleet workflows — one job per estate, nothing per repository

`renovate.yaml` and `devbox-update.yaml` run **inside** every repository
that carries a caller. That shape has one consequence that drives every
problem it has caused: each repository must be able to read an App key.
Either an organisation secret whose selected-repository list is kept by
hand, or a copy pasted into the repository's own secrets. Lists drift,
keys are copied, and a repository nobody entitled fails without a red
mark for weeks.

The fleet workflows invert it. **One scheduled job per estate**, in one
private caller repository, mints an App token and works through every
repository the App is installed on, over GitHub's API. The repositories
it updates run nothing, hold nothing, and appear in no list.

| | per-repository callers | fleet |
|---|---|---|
| a repository carries | a caller workflow and access to the key | `renovate.json` and/or `devbox.json` |
| the key lives | in every entitled repository's secrets | in the one caller repository (or, later, in a token service) |
| a repository is skipped | silently, when unentitled | loudly, in the run summary, with the reason |
| adding a repository | scaffold + entitle + install | install the App |

## What a repository has to do

Nothing in Actions. Opt-in is a **file**:

| job | opt-in file | also required |
|---|---|---|
| renovate | `renovate.json` (any name Renovate accepts) | at least one required status check on the default branch |
| parity | `devbox.json` | the same |

The required-check rule is not bureaucracy. Both jobs open pull requests
that merge on green. With nothing gating the merge, an auto-merge lands
**immediately and unvalidated** — that is how a red lint landed on a
default branch the first time devbox-update ran on a repository without
required checks. So a repository with no `check` is skipped, and the
summary says so.

## Two estates, two runner classes

A public repository must never be touched from a self-hosted runner, and
a private repository should not spend hosted minutes. So there are two
callers, and they differ only in `estate`, `runs-on` and which App:

| estate | `runs-on` | App installed on | discovery keeps |
|---|---|---|---|
| public | GitHub-hosted | the public repositories | `visibility: public` |
| private | the self-hosted pool | all repositories | `visibility: private` |

The **caller repository is private in both cases**. The public job runs
on GitHub's machines *from* that private repository, so no public
repository's CI can ever read the public App's key. Hosted minutes for a
private repository bill; measure after the first week.

## `renovate-fleet.yaml`

```yaml
# .github/workflows/renovate-public.yaml in the caller repository
name: renovate (public estate)
on:
  schedule:
    - cron: "17 */6 * * *"    # several times a day — see "why several"
  workflow_dispatch:
permissions:
  contents: read
jobs:
  renovate:
    uses: truvity/ci-workflows/.github/workflows/renovate-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: public
      runner: ubuntu-latest
      client-id: ${{ vars.RENOVATE_PUBLIC_CLIENT_ID }}
      approver-client-id: ${{ vars.CI_AUTOMATION_CLIENT_ID }}
    secrets:
      RENOVATE_APP_PRIVATE_KEY: ${{ secrets.RENOVATE_PUBLIC_PRIVATE_KEY }}
      APPROVER_APP_PRIVATE_KEY: ${{ secrets.CI_AUTOMATION_PRIVATE_KEY }}
```

Secrets are always passed **explicitly**. A caller in another organisation
cannot use `secrets: inherit` at all, and a same-org caller gains nothing
from it here: the fleet caller holds exactly the secrets it passes.

What one run does:

1. Mints the renovate App's installation token.
2. **Discovers** (`fleet-discover`): every repository the installation can
   see, minus the other estate, archived ones, and those with no required
   check. Renovate itself then skips repositories without a config
   (`requireConfig: required`, `onboarding: false`), so no repository
   ever receives an onboarding PR it did not ask for.
3. Runs Renovate once over the list.
4. **Approves**, when an approver App is configured: every open Renovate
   PR in those repositories that is non-major, still needs a review, and
   has no bot approval yet is approved as the approver App. Renovate
   cannot approve its own PRs; on a repository whose default branch
   requires one approval, this is what lets native auto-merge fire on
   green with nobody in the loop. Majors carry the `major` label and are
   never approved.

### Why several runs a day

Renovate merges a PR on its own only when the PR's checks were **already
green when the run started**. A once-a-day run that also rebuilds the
non-major batch every night therefore never merges it: each run changes
the branch, checks go pending, and the next run rebuilds it again. Two
things fix that together: the shared preset's `minimumReleaseAge` keeps
the batch from changing daily, and running the fleet every few hours
gives a green PR a run that finds it green.

### Inputs

| input | default | meaning |
|---|---|---|
| `estate` | *required* | `public` or `private` — which visibility this job may touch |
| `runner` | `ubuntu-latest` | hosted for the public estate, the pool label for the private one |
| `client-id` | *required* | the renovate App's client id |
| `approver-client-id` | `""` | the approver App's client id; empty disables the approval sweep |
| `go-modules-client-id` | `""` | an App that may read private Go modules, for `go.sum` regeneration |
| `filter` | `""` | RE2 over `owner/name`; only matches are processed — use it to shard a large estate across schedules |
| `allowed-commands` | `[]` | `RENOVATE_ALLOWED_COMMANDS`, exact strings the repositories' `postUpgradeTasks` may run |
| `log-level` | `info` | `debug` to see why a repository produced nothing |
| `timeout-minutes` | `60` | one run covers an estate |

Secrets: `RENOVATE_APP_PRIVATE_KEY` (required), `APPROVER_APP_PRIVATE_KEY`,
`GO_MODULES_APP_PRIVATE_KEY` (both optional).

## `parity-fleet.yaml`

Version parity, not dependency updates: pairs of pins that must be equal,
where **devbox leads and the other manifest follows**. The toolchain in
the shell is what builds, lints and tests, so nothing may run ahead of it.

| pair | leader | follower | rule |
|---|---|---|---|
| go | the `go` and `golangci-lint` devbox ships | `go.mod`'s `toolchain` directive | newest patch of golangci-lint's build line, never the language line, never downward — see [devbox-update.md](devbox-update.md) |
| playwright | `playwright-driver` / `playwright-test` in `devbox.lock` | `@playwright/test` and `playwright` in `package.json` | exactly the nix version; the browsers come from nixpkgs and npm must not get ahead |

Adding a pair is adding a step to the `devbox-parity` action and a row
here. Each pair is a few lines of shell over the two files.

```yaml
# .github/workflows/parity.yaml in the caller repository
name: parity
on:
  schedule:
    - cron: "0 1 * * *"       # daily; the full devbox update runs on full-update-day
  workflow_dispatch:
permissions:
  contents: read
jobs:
  private:
    uses: truvity/ci-workflows/.github/workflows/parity-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: private
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
      client-id: ${{ vars.RENOVATE_PRIVATE_CLIENT_ID }}
      git-user: renovate-private[bot]
      git-email: 12345678+renovate-private[bot]@users.noreply.github.com
    secrets:
      RENOVATE_APP_PRIVATE_KEY: ${{ secrets.RENOVATE_PRIVATE_PRIVATE_KEY }}
```

One run discovers the repositories that carry `devbox.json`, then runs the
`devbox-parity` action **once per repository as a matrix job**: checkout
with the App token, `devbox update` on the full day, every pair aligned,
one pull request on a fixed branch (`chore/devbox-update`, force-pushed,
so a re-run updates the open PR), auto-merge armed only where a required
check exists. The push runs inside devbox so the repository's own
pre-push hooks vet the result — they are the safety net, not an obstacle.

Inputs: `estate`, `runner`, `client-id`, `mode` (`auto|full|align`),
`full-update-day` (`1`), `filter`, `git-user`, `git-email`,
`timeout-minutes`. The commit author is an input because it should be the
App's bot identity, which this library cannot know.

Multi-module repositories: a `.devbox-parity.json` at the repository root
with `{"module-dirs": ["provider", "sdk"]}` names further `go.mod` files
to align. Without it, only the root module is considered — the same limit
`devbox-update.yaml` has always had.

## Migrating from the per-repository callers

1. Create the caller repository, install both renovate Apps on their
   estates, give the caller repository the keys.
2. Run the fleet jobs by hand once; read the summary. Every repository
   you expected should be listed as processed, or skipped with a reason
   you agree with.
3. Delete each repository's `renovate.yaml`, `devbox-update.yaml` and
   `auto-approve.yaml` callers. Nothing else in the repository changes.
4. Delete the org-level `RENOVATE_*` variable and secret and their
   selected lists, and any repository-level copies.

`renovate.yaml`, `devbox-update.yaml` and `auto-approve.yaml` remain in
this library until the last caller is gone, then are removed in a major
release.
