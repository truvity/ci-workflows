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

## What enrols a repository

Nothing in its Actions. A repository is processed when it is **listed in the
caller repository's enrolment file**, and it still has to carry the file the
tool itself reads:

```yaml
# fleet.yaml in the caller repository
renovate:
  public:  [cloudflare, gateway, tailscale]
  private: [bar, dms]
parity:
  public:  [cloudflare, gateway]
  private: [bar, dms]
```

| job | enrolment | the repository also needs |
|---|---|---|
| renovate | listed under `renovate.<estate>` | a renovate config at its root, and a required status check (unless `require-check: false`) |
| parity | listed under `parity.<estate>` | a `devbox.json`, and a required status check (unless `require-check: false`) |

The list is the fleet's scope, reviewed like any other change. A listed
repository the App cannot reach — not installed on it, renamed, deleted —
is an **error annotation** on the run, named individually; the rest of the
estate still runs.

The required-check rule is not bureaucracy. Both jobs open pull requests
that merge on green. With nothing gating the merge, an auto-merge lands
**immediately and unvalidated**. `require-check: false` exists for an
estate whose repositories do not automerge and review dependency PRs by
hand.

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
# .github/workflows/renovate-private.yaml in the caller repository
name: renovate (private estate)
on:
  schedule:
    - cron: "47 */6 * * *"    # several times a day — see "why several"
  workflow_dispatch:
permissions:
  contents: read
jobs:
  renovate:
    uses: truvity/ci-workflows/.github/workflows/renovate-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: private
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
      client-id: ${{ vars.RENOVATE_PRIVATE_CLIENT_ID }}
      list: renovate.private
      global-config: renovate/global.json5
    secrets:
      RENOVATE_APP_PRIVATE_KEY: ${{ secrets.RENOVATE_PRIVATE_APP_PRIVATE_KEY }}
```

Secrets are always passed **explicitly**. A caller in another organisation
cannot use `secrets: inherit` at all, and a same-org caller gains nothing
from it here.

A run is **a matrix, not one long job**:

1. `discover` (GitHub-hosted, API only) reads the list, mints the App token
   and keeps the enrolled repositories of this estate that are not archived.
2. `renovate` runs **one job per repository**, at most `max-parallel` at a
   time. Each job mints a token that reaches **only its own repository**,
   runs Renovate on it (`onboarding: false`, config required), uploads
   Renovate's dependency report, and — when an approver App is configured —
   approves that repository's non-major Renovate PRs that still need a
   review, so native auto-merge can fire on green. Majors carry the `major`
   label and are never approved.
3. `majors` combines every report into one table in the run summary: each
   package with a newer major, the newest major, and which repositories use
   it at which version. That table is what major decisions are made from.

Why a matrix: as one process, a 47-repository estate took 47 minutes and a
single transient GitHub 504 in one repository turned the whole run red.
Now a failure reds one repository's job, and only failed jobs are rerun.
Every job still spends the same App installation's API budget, which is
what `max-parallel` protects.

### Deciding majors once, in the caller repository

`global-config` names a Renovate config in the caller repository. Every job
loads it as **defaults under each repository's own config**. It is the place
for estate policy, and the intended first use is major versions:

```json5
// renovate/global.json5 in the caller repository
{
  packageRules: [
    {
      description: "Majors wait for an estate decision: found and listed on each repository's Dependency Dashboard, no PR.",
      matchUpdateTypes: ["major"],
      dependencyDashboardApproval: true,
    },
    // One entry per decision, reviewed as a PR to this file.
    {
      description: "nestjs 11 — decided 2026-09-20, all services move together.",
      matchPackageNames: ["@nestjs/**"],
      matchUpdateTypes: ["major"],
      allowedVersions: "<12",
      dependencyDashboardApproval: false,
    },
  ],
  // Security fixes never wait for a decision.
  vulnerabilityAlerts: { dependencyDashboardApproval: false },
}
```

Two limits worth knowing. Renovate's `force` cannot carry per-package
rules — it becomes one rule matching every package — so this is a set of
**defaults**: a repository can still override them in its own
`renovate.json`, which makes the exception visible in that repository.
And a decision sets what each repository is **offered**; each still merges
on its own green, so a repository with red CI lags until it is fixed.

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
| `list` | `""` | dotted path to the enrolment list in `repositories-file`, e.g. `renovate.private` |
| `repositories-file` | `fleet.yaml` | the enrolment file in the caller repository |
| `global-config` | `""` | the estate policy file in the caller repository |
| `max-parallel` | `4` | repositories processed at once |
| `runner` | `ubuntu-latest` | hosted for the public estate, the pool label for the private one |
| `client-id` | *required* | the renovate App's client id |
| `approver-client-id` | `""` | the approver App's client id; empty disables the approval sweep |
| `go-modules-client-id` | `""` | an App that may read private Go modules, for `go.sum` regeneration |
| `require-check` | `true` | skip repositories with no required status check; `false` only for an estate whose repositories do not automerge |
| `filter` | `""` | RE2 over `owner/name`; only matches are processed — use it to shard a large estate across schedules |
| `allowed-commands` | `[]` | `RENOVATE_ALLOWED_COMMANDS`, exact strings the repositories' `postUpgradeTasks` may run |
| `log-level` | `info` | `debug` to see why a repository produced nothing |
| `timeout-minutes` | `30` | per repository |

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

Inputs: `estate`, `runner`, `client-id`, `list`, `repositories-file`, `mode` (`auto|full|align`),
`full-update-day` (`1`), `filter`, `require-check` (`true`), `git-user`, `git-email`,
`timeout-minutes`. The commit author is an input because it should be the
App's bot identity, which this library cannot know.

Multi-module repositories: a `.devbox-parity.json` at the repository root
with `{"module-dirs": ["provider", "sdk"]}` names further `go.mod` files
to align. Without it, only the root module is considered — the same limit
`devbox-update.yaml` has always had.

## Migrating from the per-repository callers

Per repository, in this order:

1. Add it to the caller repository's `fleet.yaml` under the lists it uses
   today (`renovate.<estate>`, `parity.<estate>`).
2. Dispatch the fleet jobs and read the summary: the repository is listed as
   processed, not as an error.
3. In the repository, delete `renovate.yaml`, `devbox-update.yaml` and
   `auto-approve.yaml`. Nothing else in it changes.

Once every caller is gone, switch on the caller repository's schedules and
delete the organisation-level `RENOVATE_*` variable and secret, their
selected lists, and any repository-level copies.

`renovate.yaml`, `devbox-update.yaml` and `auto-approve.yaml` remain in
this library until the last caller is gone, then are removed in a major
release.
