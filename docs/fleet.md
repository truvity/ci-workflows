# Fleet workflows — one job per estate, nothing per repository

Dependency updates and version parity used to run **inside** every
repository, from a caller workflow of its own. That shape had one
consequence that drove every problem it caused: each repository had to
be able to read an App key. Either an organisation secret whose
selected-repository list was kept by hand, or a copy pasted into the
repository's own secrets. Lists drift, keys are copied, and a repository
nobody entitled failed without a red mark for weeks.

The fleet workflows invert it. **One scheduled job per estate**, in one
private caller repository, mints an App token and works through every
repository the App is installed on, over GitHub's API. The repositories
it updates run nothing, hold nothing, and appear in no list.

| | the old per-repository callers | fleet |
|---|---|---|
| a repository carries | a caller workflow and access to the key | `renovate.json` and/or `devbox.json` |
| the key lives | in every entitled repository's secrets | in the one caller repository, or nowhere: `token-source: access-roster` |
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
caller-parity:
  public:  [cloudflare, gateway, tailscale]
```

| job | enrolment | the repository also needs |
|---|---|---|
| renovate | listed under `renovate.<estate>` | a renovate config at its root, and a [required status check](#what-counts-as-a-required-status-check) (unless `require-check: false`) |
| parity | listed under `parity.<estate>` | a `devbox.json`, and a [required status check](#what-counts-as-a-required-status-check) (unless `require-check: false`) |
| caller-parity | listed under the list `caller-parity-list` names, or under `parity.<estate>` when it names none | nothing — it reads, and a repository that carries neither caller file is reported as such |

The list is the fleet's scope, reviewed like any other change. A listed
repository the App cannot reach — not installed on it, renamed, deleted —
is an **error annotation** on the run, named individually; the rest of the
estate still runs.

The required-check rule is not bureaucracy. Both jobs open pull requests
that merge on green. With nothing gating the merge, an auto-merge lands
**immediately and unvalidated**. `require-check: false` exists for an
estate whose repositories do not automerge and review dependency PRs by
hand.

### What counts as a required status check

A branch can be gated in two entirely separate ways, and **either one
makes the repository eligible**:

| source | read with | the App needs |
|---|---|---|
| a repository **ruleset** (repository- or organisation-level) | `GET /repos/{owner}/{repo}/rules/branches/{branch}` — the *effective* rules for that branch, already merged across every ruleset that applies, `evaluate` and `disabled` ones left out | `Metadata: read` (every installation token has it) |
| **classic branch protection** | `GET /repos/{owner}/{repo}/branches/{branch}/protection` first — authoritative and viewer-independent; it answers `404 Branch not protected` when there is none | `Administration: read` |
| ↳ fallback when the above is not readable | GraphQL `defaultBranchRef.refUpdateRule.requiredStatusCheckContexts` | nothing beyond seeing the repository |

Discovery counts a repository as gated when **either** source requires at
least one check. Reading classic protection alone skipped every
repository whose merge gate had moved into a ruleset — and a skip is the
normal outcome for most of an installation, so nothing looked wrong.

The GraphQL fallback exists because the fleet App does not carry
`Administration: read`; it is a fallback rather than the first choice
because `refUpdateRule` reports the rule **as it applies to the viewer**.
On a branch whose protection does not apply to administrators
(`enforce_admins: false`), an administrator is told there are no required
contexts at all — so it under-reports for exactly the identity most
likely to be debugging the rule by hand.

**A read that fails is `unknown`, never `no`.** If a source answers 403,
or a 404 that means "not yours to read" rather than "not protected", the
repository is **kept** and processed, the run carries a warning, and the
step summary lists it under *Required-check rule not decided*. A
repository must never be dropped because a read failed — that is
indistinguishable from a repository with nothing to do.

The rule is exercised against a stub API by
[`hack/discover-cases.sh`](https://github.com/truvity/ci-actions/blob/master/hack/discover-cases.sh),
which this repository's own CI runs: either source alone, both, neither,
a ruleset with rules but no status-check rule, a protection object with
no required checks, and each of the failure shapes.

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

## Where the tokens come from

Both workflows take `token-source`. So does the shared
[`auto-release.yaml`](estate-lifecycle.md#where-the-tagging-token-comes-from),
which is not a fleet workflow — it runs inside each repository — but
takes the same two sources under the same names:

| `token-source` | the caller passes | each job |
|---|---|---|
| `app-key` (default) | `client-id` inputs and the App private keys as secrets | mints with `actions/create-github-app-token` |
| `access-roster` | `access-roster-issuer` and catalogue ids (`github-app`, …); no secret | exchanges its own GitHub OIDC token at the issuer for an installation token, via the [access-roster action](https://github.com/truvity/access-roster) |

With `access-roster` there is no key to hold, copy or rotate: the issuer
keeps the Apps, and its grants decide which **job** may have a token of
which App, for which repositories and with which permissions. Every token
is asked for as narrow as the job's work:

| workflow | job | App | repositories | permissions |
|---|---|---|---|---|
| renovate-fleet | `discover` | `github-app` | all (discovery lists them) | the grant's |
| renovate-fleet | per repository | `github-app` | that one | the grant's |
| renovate-fleet | per repository | `go-modules-github-app` | all (any module) | `contents:read` |
| renovate-fleet | per repository | `approver-github-app` | that one | `pull_requests:write` |
| parity-fleet | `discover` | `github-app` | all | the grant's |
| parity-fleet | per repository | `github-app` | that one | `contents:write`, `pull_requests:write` |
| parity-fleet | `caller-parity` | `github-app` | all (one table covers the estate) | `contents:read` |
| auto-release | `tag-roster` | `github-app` | the repository it runs in | `contents:write`, `pull_requests:read` |

Discovery is not narrowed in permissions although it only reads: the
required-check rule's fallback, GraphQL's `refUpdateRule`, answers for
the viewer, and a weaker token could find no required check where the
repository's own job would. Its two REST sources ask for no more than the
grant already gives — `Metadata: read` for the effective rules of a
branch, and `Administration: read` for classic protection, which the App
does not have and does not need (the fallback covers it).

**The caller grants `id-token: write`**, in either mode: the jobs that mint
declare it, and a called workflow can only narrow its caller's permissions.
(`auto-release.yaml` is the exception, and deliberately: its two sources
are two jobs, so the `app-key` one asks for nothing new and its dozen
callers keep working untouched.)

An issuer pins a grant to the job's identity token: the caller repository,
its default branch, the event, the caller file (`workflow_ref`) and this
library's file (`job_workflow_ref`, `truvity/ci-workflows/.github/workflows/renovate-fleet.yaml@<ref>`).
Pin this library **by commit SHA**: a `*` in a matcher does not cross a
`/`, so `@refs/tags/v2` would not match `@*`. One caller **file** per
identity: GitHub's token names the file, not the job, so two jobs in one
file cannot hold different grants. Hence a public and a private file for
each workflow.

`debug-oidc-claims: true` prints the `discover` job's claims —
`repository`, `ref`, `ref_type`, `event_name`, `workflow_ref`,
`job_workflow_ref`, `sha`, never the token — to compare against the
issuer's matchers on a first run.

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
  id-token: write
jobs:
  renovate:
    uses: truvity/ci-workflows/.github/workflows/renovate-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: private
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
      list: renovate.private
      global-config: renovate/global.json5
      token-source: access-roster
      access-roster-issuer: https://access.example
      github-app: renovate-private
      approver-github-app: ci-automation
      go-modules-github-app: renovate-private
```

With keys instead, `client-id: ${{ vars.RENOVATE_PRIVATE_CLIENT_ID }}` and
`secrets: { RENOVATE_APP_PRIVATE_KEY: ${{ secrets.RENOVATE_PRIVATE_APP_PRIVATE_KEY }} }`
replace the last four inputs.

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
| `token-source` | `app-key` | `app-key` or `access-roster` — see [Where the tokens come from](#where-the-tokens-come-from) |
| `access-roster-issuer` | `""` | the issuer URL (`access-roster`) |
| `github-app` | `""` | the renovate App's catalogue id (`access-roster`) |
| `approver-github-app` | `""` | the approver App's catalogue id (`access-roster`); empty disables the approval sweep |
| `go-modules-github-app` | `""` | an App whose `contents:read` token reads private Go modules (`access-roster`), often the renovate App |
| `client-id` | `""` | the renovate App's client id (`app-key`) |
| `approver-client-id` | `""` | the approver App's client id (`app-key`); empty disables the approval sweep |
| `go-modules-client-id` | `""` | an App that may read private Go modules, for `go.sum` regeneration (`app-key`) |
| `debug-oidc-claims` | `false` | print the `discover` job's OIDC claims, not the token |
| `require-check` | `true` | skip repositories with no required status check, from [either source](#what-counts-as-a-required-status-check); `false` only for an estate whose repositories do not automerge |
| `filter` | `""` | RE2 over `owner/name`; only matches are processed — use it to shard a large estate across schedules |
| `allowed-commands` | `[]` | `RENOVATE_ALLOWED_COMMANDS`, exact strings the repositories' `postUpgradeTasks` may run |
| `log-level` | `info` | `debug` to see why a repository produced nothing |
| `timeout-minutes` | `30` | per repository |

Secrets, all optional and read only with `app-key`: `RENOVATE_APP_PRIVATE_KEY`
(needed there), `APPROVER_APP_PRIVATE_KEY`, `GO_MODULES_APP_PRIVATE_KEY`.
`discover` checks the combination before anything runs.

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
# .github/workflows/parity-private.yaml in the caller repository
name: parity (private estate)
on:
  schedule:
    - cron: "0 1 * * *"       # daily; the full devbox update runs on full-update-day
  workflow_dispatch:
permissions:
  contents: read
  id-token: write
jobs:
  parity:
    uses: truvity/ci-workflows/.github/workflows/parity-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: private
      runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}
      token-source: access-roster
      access-roster-issuer: https://access.example
      github-app: renovate-private
      git-user: example-renovate-private[bot]
      git-email: 12345678+example-renovate-private[bot]@users.noreply.github.com
```

With a key instead: `client-id` and the `RENOVATE_APP_PRIVATE_KEY` secret
replace `token-source`, `access-roster-issuer` and `github-app`.

One run discovers the repositories that carry `devbox.json`, then runs the
`devbox-parity` action **once per repository as a matrix job**: checkout
with the App token, `devbox update` on the full day, every pair aligned,
one pull request on a fixed branch (`chore/devbox-update`, force-pushed,
so a re-run updates the open PR), auto-merge armed only where a required
check exists — read from
[both sources](#what-counts-as-a-required-status-check), and left unarmed
when neither answers. The push runs inside devbox so the repository's own
pre-push hooks vet the result — they are the safety net, not an obstacle.

Inputs: `estate`, `runner`, `token-source` (`app-key|access-roster`),
`access-roster-issuer`, `github-app`, `client-id`, `debug-oidc-claims`,
`list`, `repositories-file`, `mode` (`auto|full|align`), `full-update-day`
(`1`), `filter`, `require-check` (`true`), `git-user`, `git-email`,
`timeout-minutes`, and the four `caller-parity*` inputs of the
[second check](#caller-parity--the-shared-caller-files) this workflow
carries. The commit author is an input because it should be the
App's bot identity, which this library cannot know: `git-user` is the bot
login, `<app name>[bot]`; an empty `git-email` is looked up from it
(`<bot user id>+<login>@users.noreply.github.com`).

### `.devbox-parity.json`

Optional, at the repository root, read off the default branch before the
checkout. It is how a repository says something about itself that the run
cannot know. Every key is optional; no file at all means every default.

| key | values | default | meaning |
|---|---|---|---|
| `module-dirs` | array of paths | `[]` | further `go.mod` files to align, relative to the root. The root module is always considered — without this key it is the only one, which for a long time was the only thing alignment could see. |
| `mode` | `auto`, `align` | the run's `mode` input | the parity mode for this repository. |

```json
{
  "mode": "align",
  "module-dirs": ["provider", "sdk"]
}
```

`mode` exists for the repository whose hooks refuse a full `devbox
update`: one whose pinned tools generate committed files — golden
renders, generated clients — that a human regenerates on purpose, so an
unattended `devbox update` either moves them behind everyone's back or is
refused outright by a pre-push hook. Such a repository used to be left
out of the fleet and keep a caller of its own; with `align` it is aligned
by the same run as everyone else, and only its *followers* move.

A repository's own `mode` wins over the run's, a dispatched `full`
included — the point is that the repository, not the dispatcher, knows
this about itself. `full` is a run-wide decision and is not accepted in
the file; an unknown value is a warning and the run's mode is used.
Writing `"mode": "auto"` therefore means "full updates are fine here,
whatever this run was dispatched with", which is also what no file at all
means for a run left on the default.

What `align` runs is exactly what every repository gets on a day that is
not `full-update-day`: `devbox update` is skipped, `devbox.json` and
`devbox.lock` are untouched, each pair is aligned to the pin already in
`devbox.lock` (the go `toolchain` directive, the playwright npm
packages), and a pull request is opened on `chore/devbox-update` only if
one of them actually moved. The commit and the push run inside devbox, so
the repository's own hooks still vet the result.

### `caller-parity` — the shared caller files

Version parity is about the pins *inside* a repository. This is about the
thin caller workflows every repository carries to delegate here, and the
observation that two of them are **one kit in substance**:

| file | carried by | identical, normalised |
|---|---|---|
| `.github/workflows/security.yaml` | 11 public repositories | **11 of 11** — four distinct files as written, one workflow |
| `.github/workflows/auto-release.yaml` | 13 public repositories | **12 of 13** |

The thirteenth had lost the `push: branches: [master]` trigger, and with
it the security lane: a vulnerability fix there waited for Monday
instead of releasing on merge. Nothing in CI said so. It was found by
reading thirteen files side by side, which is exactly the kind of work
that does not happen twice.

So `caller-parity: true` compares each enrolled repository's copy
against a canonical one kept here, and **reports**.

#### What is compared, and what is not

Substance, not bytes. Both sides are normalised before comparison, and
each exemption is deliberate:

| ignored | why |
|---|---|
| comment lines | a repository explains itself in its own words. The four prose variants of `security.yaml` were four ways of saying the same thing. |
| blank lines | they follow the comments they separated. |
| the `cron:` line | **the schedule is staggered per repository on purpose** — repositories that tag in the same minute produce downstream pin pull requests that race each other's rebases. Comparing it would report the whole estate as differing, which teaches everyone to ignore the table. |
| this library's pinned ref in a `uses: …/.github/workflows/…@<sha>` | renovate moves it in each repository on its own schedule, so between a release here and renovate's sweep there the estate is legitimately spread over two pins. The pin has a keeper already. A **third-party** action pin inside a caller is *not* exempt: it is compared. |

Everything else has to match. A repository is free to explain itself; it
is not free to change what runs.

#### What it does NOT do

**It opens no pull request and rewrites nothing.** A repository that
differs appears in the run summary with its normalised diff, and a
human decides which side is wrong — the repository, or the canonical
copy for the whole estate. Automation that rewrites a repository's own
CI is a thing to earn, not to start with, and the estate has to be able
to read what would change before anything does it. `fail-on-diff` turns
the report into a gate; it stays off until the table is clean.

#### Absent is not differing

Four states per file, and the summary keeps them apart:

| state | meaning |
|---|---|
| `same` | identical once normalised |
| `differs` | listed with a normalised diff, and a warning annotation |
| `absent` | the repository does not carry the file. **Often correct** — a repository that releases nothing has no `auto-release.yaml`, one with no Go module has no `security.yaml`. Never a warning on its own. |
| `unreadable` | a read failed. Never reported as any of the other three; a read that fails is not an answer. |

Satisfying the check is therefore cheap: 11 of 11 and 12 of 13 already
did, without knowing it existed. A new repository copies the kit file
verbatim and gives its `cron:` a minute of its own.

#### One kit, and the differences that are decisions

A second kind of estate was measured on 2026-09-21: private repositories,
where only a few carry either file at all.

| file | carried by | against the kit |
|---|---|---|
| `auto-release.yaml` | 1 of the private repositories measured | **`same`** — the prose is its own and the `cron:` minute its own, and nothing else differs |
| `security.yaml` | 3, across two estates | **three shapes, no two alike** |

The first row is the useful one: the kit is not the public estate's kit,
it is the estate's kit, and a private repository that copied it years
apart still matches it.

The second row is the answer to "should a private estate get a kit of
its own", and it is **no**. The three files differ from the canonical
copy in three unrelated ways — two pass extra `with:` inputs because
their jobs run on a pool and through a module proxy of their own, one
of those two also passes a secret, and the third narrows its trigger
list, adds a `concurrency:` block and renames its job. Each of those is
argued at length in the file that carries it. There is no shape a
second kit could hold that all three would match, and a kit that held
any one of them would bless one repository's local decision as the
estate's rule.

So an estate whose callers look like this is enrolled **against these
kits**, and the table carries a `differs` row for each deliberate local
decision, with the normalised diff that says what it is. That is the
check working. `fail-on-diff` is what a clean table would earn, and it
stays off while the table is honest instead.

The two additive shapes are in
[`hack/caller-parity-cases.sh`](https://github.com/truvity/ci-actions/blob/master/hack/caller-parity-cases.sh)
— until they were measured every case there removed or rewrote
something, and a comparison that only notices deletions would have
reported both as parity.

#### Where the canonical copies live

[`caller-parity/kits/`](https://github.com/truvity/ci-actions/tree/master/caller-parity/kits)
in truvity/ci-actions, one file per caller workflow, named for the path
it is compared against (`security.yaml` →
`.github/workflows/security.yaml`). They sit inside the action so that
they are pinned by the same SHA the workflow pins the
action with, and so that `self-check.yaml`'s "pins are current" gate
covers them: a kit that changes without the pin moving is caught the
same way a changed action is. **Adding a third caller to the check is
dropping a file in that directory.**

An estate whose callers differ from this one points
`caller-parity-kits` at a directory in its **caller repository**
instead, the same way `global-config` keeps renovate's estate policy
there. It **replaces the whole set**, not one file: an estate that
points at its own directory must copy across the kits it does *not*
disagree with, and those copies then drift from the ones here with
nothing comparing them. Worth it for an estate whose callers really are
a different workflow; not worth it for one that disagrees about a file
or two, which is what a `differs` row is for.

#### Inputs

| input | default | meaning |
|---|---|---|
| `caller-parity` | `false` | run the check at all. Off by default: it is new, and a scheduled run that suddenly grows a table of findings is a surprise. |
| `caller-parity-list` | `""` | dotted path to its enrolment list, e.g. `caller-parity.public`. Empty uses `list`. |
| `caller-parity-kits` | `""` | a directory in the caller repository holding that estate's own canonical copies. Empty uses this library's. |
| `caller-parity-fail-on-diff` | `false` | fail the job on a difference, once the estate is clean enough to gate. |

The job runs on a GitHub-hosted runner in either estate, like
`discover`: it only reads the API. It discovers its own repositories,
with two of `fleet-discover`'s rules relaxed on purpose —
`require-check: false`, because the rule exists for automation that
merges on green and this check merges nothing, and no `require-file`,
because the subject is the caller workflows and a repository without a
`devbox.json` still has them.

The comparison is a script, `caller-parity.sh`, and its rules are
exercised against a stub API by
[`hack/caller-parity-cases.sh`](https://github.com/truvity/ci-actions/blob/master/hack/caller-parity-cases.sh),
which this repository's own CI runs: identical, prose rewritten, cron
staggered, library pin not yet moved, a dropped trigger, an added
`with:` input, an added top-level block with the job renamed, an absent
file, a 403 and an unreachable repository.

## The migration off the per-repository callers is done

Both estates are on the fleet jobs, and **v3.0.0 removed
`renovate.yaml`, `devbox-update.yaml` and `auto-approve.yaml` from this
library** (2026-09-21, once no repository in either organisation still
carried one of them). A caller pinned to a v2 SHA keeps resolving that
commit and keeps working; there is no v3 workflow of those names to
repoint it at, so such a repository is enrolled with the fleet instead.

What that took, per repository, and what it is worth knowing for the
next estate that adopts the fleet:

1. Add it to the caller repository's enrolment file under the lists it
   uses (`renovate.<estate>`, `parity.<estate>`). A repository whose own
   caller ran parity in a fixed mode carries that mode over in its
   `.devbox-parity.json` — the fleet run's mode is only a default.
2. Dispatch the fleet jobs and read the summary: the repository is
   listed as processed, not as an error.
3. In the repository, delete the callers. Nothing else in it changes.

Then switch on the caller repository's schedules and delete the
organisation-level variables and secrets those callers read, their
selected-repository lists, and any repository-level copies. The approval
sweep `auto-approve.yaml` did per repository is now a step inside
`renovate-fleet.yaml`, configured with `approver-github-app` or
`approver-client-id` and skipped when neither is set.
