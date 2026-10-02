# ci-workflows

The reusable GitHub Actions workflows every repository in both Truvity
organisations calls: the merge gate, integration suites, releases,
automatic patch tags, and the estate-wide renovate and parity jobs. It
also carries the shared renovate preset, `github>truvity/ci-workflows`.

## What ships

| workflow | what it does | the caller grants | required inputs and secrets | called from |
| -- | -- | -- | -- | -- |
| [`check.yaml`](.github/workflows/check.yaml) | Runs the caller's task-runner recipes, one parallel job per recipe, after refusing self-hosted runners in a public repository (`runners`) and untagged library pins (`pins`); opt-in `policy-conformance` | `contents: read`; `id-token: write` only if recipes reach AWS or Kubernetes; `packages: read` only for GitHub Packages | `recipes` | each repository's `ci.yaml`, and its `security.yaml` with `recipes: '["vuln"]'` |
| [`integration.yaml`](.github/workflows/integration.yaml) | Integration suites for a gemaal-shaped project, one job per lane: build, install, test, logs, uninstall. Picks a kind tier (public repositories) or the shared development cluster (private) | `contents: read`, `id-token: write` | `lanes`; `policy-version` on the kind tier; `gemaal-namespace` and the cluster inputs on the shared tier | an `integration` caller beside `ci.yaml` |
| [`release-public.yaml`](.github/workflows/release-public.yaml) | On a tag: goreleaser binaries and ko images to GHCR, then charts packaged deterministically with helmctl and pushed to `oci://ghcr.io/truvity/charts` | `contents: write`, `packages: write` | none; `charts` (names under `chart-root`, or repository-root paths containing a `/`), `ko-docker-repo`, `nix-flakes`, `sourcemaps-image` (+ `sourcemaps-dir`, `sourcemaps-app`: push a web app's source maps with smctl after goreleaser) as the repository ships them | a public repository's `release.yaml` |
| [`release-private.yaml`](.github/workflows/release-private.yaml) | On a tag: the release command with tag-scoped GitHub OIDC into an ECR account, optionally on the CI plane's warm builders, gated on the tagged commit's checks being green | `contents: read`, `id-token: write`, `checks: read` | `role-to-assume`, `ecr-registries`, `command`; secret `goreleaser-key` for goreleaser-pro | a private repository's `release.yaml` |
| [`auto-release.yaml`](.github/workflows/auto-release.yaml) | Cuts the next patch tag weekly when `master` has moved past the latest release, and at once for a merged `security`-labelled pull request or a hand-written conventional `fix:` (renovate's never), first giving the CHANGELOG its `## vX.Y.Z` heading by pull request (`changelog-heading: never` opts out) | `contents: read`; `id-token: write` with `token-source: access-roster` | `token-source: access-roster` needs `access-roster-issuer` and `github-app`; `app-key` needs `app-id` and secret `CI_AUTOMATION_PRIVATE_KEY` | a repository's `auto-release.yaml`, guarded by `vars.AUTO_RELEASE` |
| [`renovate-fleet.yaml`](.github/workflows/renovate-fleet.yaml) | Renovate for a whole estate from one caller: a matrix job per enrolled repository, estate policy in the caller | `contents: read`, `id-token: write` | `estate`; the token inputs, or secrets `RENOVATE_APP_PRIVATE_KEY` (and optional approver and Go-modules keys) | an estate's `ci-caller` repository |
| [`parity-fleet.yaml`](.github/workflows/parity-fleet.yaml) | Version parity for a whole estate: devbox leads, the other manifests follow, one pull request per repository that moved; optionally reports caller-workflow drift | `contents: read`, `id-token: write` | `estate`, `git-user`; the token inputs, or secret `RENOVATE_APP_PRIVATE_KEY` | an estate's `ci-caller` repository |

Every input is described in full in the workflow file. The composite
steps these are built from live in
[truvity/ci-actions](https://github.com/truvity/ci-actions).

## Who it is for

Every repository in the `truvity` and `trust-form` organisations, and
anyone else who wants the same shape: a repository keeps thin caller
workflows that pin one of these by commit, and the logic lives here.
Nothing here names an account, a cluster or a hostname; each estate
passes its own as inputs and organisation variables.

## The model

A repository carries a few **thin callers**: `ci.yaml` calling
`check.yaml`, `security.yaml` calling `check.yaml` with the `vuln`
recipe on a schedule, `release.yaml` calling one of the two release
workflows on a tag, and `auto-release.yaml`. Dependency updates and
version parity are **not** callers in each repository: one job per
estate runs them from that estate's `ci-caller` repository, over an
enrolment list ([docs/fleet.md](docs/fleet.md)).

**Pin the commit of a tag, never a tag or a branch.** Every repository
in both organisations executes this code, so a compromise here reaches
the whole estate, and tags move. Take the commit, not the annotated tag
object: `git rev-parse vX.Y.Z^{commit}`. `check.yaml`'s `pins` job
refuses a pin into ci-workflows or ci-actions that is not the commit of
a tag.

**The caller owns permissions.** A reusable workflow's `permissions`
block can only cap what the caller grants, never widen it, so
`check.yaml`, `integration.yaml` and `release-private.yaml` declare none,
and each caller grants what the table above lists, no more.

**A reusable workflow cannot supply a required status context.** See
[Required checks](#required-checks) below: the name a ruleset requires
is a fan-in job in the caller.

## Install and a worked example

Nothing to install. A repository with a Justfile that has `build`,
`test` and `lint` recipes adds `.github/workflows/ci.yaml`:

```yaml
name: ci
on:
  pull_request:
    branches: [master]
  push:
    branches: [master]

permissions:
  contents: read

jobs:
  recipes:
    uses: truvity/ci-workflows/.github/workflows/check.yaml@83a33664e82b4df3764ed4b4544707320b51db92 # v3.13.1
    with:
      recipes: '["build","test","lint"]'

  # The context the ruleset requires. Strict "success": a skipped call
  # must not hand anyone a green required check.
  check:
    needs: recipes
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: '[ "${{ needs.recipes.result }}" = "success" ]'
```

On the next pull request the checks read `recipes / runners`,
`recipes / pins`, `recipes / build`, `recipes / test`,
`recipes / lint`, and `check`. Each recipe runs inside the repository's
devbox and fails if it leaves the working tree modified. With `runner`
unset every job runs on `ubuntu-latest`, which is what a public
repository must use; a private repository passes its scale set in
`runner` (and, for measured recipes, `small-recipes`/`medium-recipes`).

To hold a component repository to the component contract as well:

```yaml
    with:
      recipes: '["build","test","lint"]'
      policy-conformance: true          # report, as warnings
      policy-conformance-strict: false  # true: fail on a broken rule
```

`policy-conformance` runs truvity/ci-actions' action of that name on a
hosted runner and prints one line per rule, C1 to C12, pinned to its
v1.3.0 release.

### Required checks

GitHub reports every job of a called workflow as
`<caller job> / <its own name>`, so a ruleset asking for a bare `check`
or `integration` never sees one. It fails in the worst way: an
unsatisfiable required context is **pending**, not failing, and nothing
goes red. A private caller wedged every pull request for a day this way
with all six real checks green, after the fan-in job had been moved into
this repository, where it could only report as
`integration / integration`. So the fan-in lives in the caller, next to
the call, as in the example above.

## Consumers

As of 2026-09-29, by a code search of each organisation's workflow
files:

| consumer | through |
| -- | -- |
| truvity public repositories: access-roster, amazon-eks-pod-identity-webhook, argocd-ecr-updater, cloudflare, cnpg, gateway, gemaal, github-structure, nats, observability, ocictl, openbao, tailscale | `check`, `release-public`, `auto-release` |
| truvity/audit, truvity/policy | `check`, `integration` (kind tier), `release-public` |
| truvity/ci-cache | `check`, `release-public` |
| truvity/ci-plane | `check`, `auto-release` |
| truvity/workstation | `check` |
| four private truvity repositories, gitops among them | `check`, `integration` (shared tier), `release-private`, `auto-release` |
| 19 private trust-form repositories | `check` |
| `ci-caller` in each organisation | `renovate-fleet`, `parity-fleet` |
| every repository that extends `github>truvity/ci-workflows` in `renovate.json` | the preset, `default.json` |

## Neighbours

- **ci-workflows → ci-actions → ci-cache; ci-plane hosts the runners.**
  This repository is the only thing a caller pins.
  [ci-actions](https://github.com/truvity/ci-actions) holds the
  composite steps these workflows call;
  [ci-cache](https://github.com/truvity/ci-cache) owns cache wiring (its
  `setup` action, called from `setup-devbox`) and the cache server;
  [ci-plane](https://github.com/truvity/ci-plane) is where work executes
  (runner and nix-worker images, `arc-runners`, `ci-builders`).
- **[policy](https://github.com/truvity/policy)**: the component contract
  every public repository is held to, and the `hack/kind/` box the kind
  tier of `integration.yaml` runs.
- **[github-structure](https://github.com/truvity/github-structure)**:
  what a repository *is* (settings, rulesets, required contexts); this
  repository is what it *does*.
- **[access-roster](https://github.com/truvity/access-roster)**: its
  action mints the fleet and auto-release tokens with
  `token-source: access-roster`, and its `accessctl` is how a job reaches
  AWS and the cluster.

## Documentation

- [docs/estate-lifecycle.md](docs/estate-lifecycle.md): a repository
  from birth to autopilot. Start here when setting one up.
- [docs/tiers.md](docs/tiers.md): `integration.yaml`'s two tiers, the
  fork refusal, and why a kind lane's images stay on the runner.
- [docs/fleet.md](docs/fleet.md): `renovate-fleet` and `parity-fleet`,
  enrolment, tokens, and caller parity.
- [docs/renovate.md](docs/renovate.md): running the renovate engine,
  and repositories whose pin bumps regenerate files.
- [docs/devbox.md](docs/devbox.md) and
  [docs/devbox-update.md](docs/devbox-update.md): one toolchain for
  laptops and CI, and how a Go repository's toolchain triple stays
  aligned.
- [docs/secrets.md](docs/secrets.md): a job reads its third-party
  secrets from OpenBao at run time.
- [docs/golden-renders.md](docs/golden-renders.md): golden chart
  renders, and the canonical `hack/golden.sh`.
- The component contract lives in
  [truvity/policy](https://github.com/truvity/policy/blob/master/docs/contracts/component.md);
  [docs/component-contract.md](docs/component-contract.md) points there
  and says what changed.
- [CHANGELOG.md](CHANGELOG.md): every release.

## The rule that makes this repository public

**Mechanism only.** Account ids, role ARNs, registry hostnames, bucket
names, cluster names and internal DNS are caller inputs or organisation
variables, never content here. Public history cannot be unpublished, so
`hack/leak-canary.sh` enforces the rule in CI; the component repositories
vendor that script from here.

Public because a private repository's reusable workflows cannot be
called across an organisation boundary, and *internal* visibility needs
an Enterprise plan neither organisation has. Public is what lets
`trust-form` call these directly: no mirror, no sync job, no drift
check.

## Status

Used in production by both organisations. The latest tag is v3.14.2
(2026-09-29). There are 82 tags; GitHub releases exist for v1.0.0 to
v2.6.0 and, resuming at v3.14.0, for v3.14.0 to v3.14.2 — nothing
between v3.0.0 and v3.13.1 has one. The release GitHub marks "Latest"
is now v3.14.2, so it agrees with the tags again; read the tags and
[CHANGELOG.md](CHANGELOG.md) for anything earlier.

## Development

`just check` runs what CI runs on every pull request. Set up your
environment with `direnv allow`, or run `devbox run just <recipe>` to
call a recipe without direnv.

The recipes are:

- `just lint` — actionlint over every workflow.
- `just pins` — verify all pins point to release tags.
- `just runners` — verify the repository uses public runners.
- `just leak-canary` — scan for secrets and sensitive data.
- `just check` — run all recipes (the merge gate).

`check` green is the whole merge gate: no approving review is required,
and renovate's pull requests merge themselves when it goes green. A fork
pull request needs no grant. The composite actions are changed in
ci-actions and reach here as a pin bump.

## Releasing

A release is an annotated `vX.Y.Z` tag on `master`, pushed by a
maintainer, with its heading added to [CHANGELOG.md](CHANGELOG.md) in
the change being tagged. A change that makes an existing caller's `with:`
block stop working is a major. This repository has no auto-release
caller and no release workflow of its own, so a tag creates no GitHub
release; consumers pin the tag's commit, and renovate moves those pins.

## Licence

MIT, as [LICENSE](LICENSE).
