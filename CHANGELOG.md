# Changelog

Every release of truvity/ci-workflows, newest first. Pin the commit of a
tag (`git rev-parse vX.Y.Z^{commit}`), with the version in a trailing
comment. Entries from v3.0.0 to v3.13.1 are reconstructed from `git log`:
those tags have no GitHub release; v3.14.0 on do.

## v3.17.0

- truvity/ci-actions pins move to v1.5.0: `policy-conformance` accepts paired C13 exemptions (a list of entries, each with its own `checks`, `paths` and a required `reason`, so one exemption cannot widen another) and matches quoted exemption items.

## v3.16.0

- truvity/ci-actions pins move to v1.4.0: `policy-conformance` enforces C10's check-recipe half (the Justfile's `check` must not reach `vuln`), checks C13 (no estate fact as a default, no ticket key in a tracked file) and follows the contract's text for C5 (an automatic patch needs no heading of its own). A caller that set `skip: C13` no longer needs to; one that sets `strict: true` now fails on a hit.

## v3.15.0

- `auto-release.yaml` releases at once on a push whose merged change is a hand-written conventional `fix:`, `fix(scope):` or `fix!:`, besides the `security` lane. Renovate PRs (a Bot login containing `renovate`, or the `dependencies` label) never take it, so `fix(deps)` bumps still batch; `feat`, `chore`, `docs`, reverts and the rest wait for the weekly batch. The PR title decides; a title without a conventional prefix defers to the PR's commits (rebase merges). The bump stays one patch, `fix!` included. `workflow_dispatch` and the schedule are unchanged.
- `hack/auto-release-cases.sh` tests the gate, and runs in `self-check`.

## v3.14.2

- `default.json` labels vulnerability PRs `security` and automerges them, so every repo gets auto-release's security lane without a local copy.

## v3.14.1

- truvity/ci-actions pins move to v1.3.0: policy-conformance checker fixes (C1, C11, C12) and the `.github/policy-conformance.yaml` exemption file.

## v3.14.0

- `check.yaml` gains opt-in `policy-conformance` and `policy-conformance-strict` inputs that run truvity/ci-actions' `policy-conformance` action (v1.2.0) against the calling repository.
- Every `truvity/ci-actions` pin moves to v1.2.0, which pins ci-cache at a tagged release and inlines its own auto-release.
- Doctrine lives in truvity/policy: `docs/component-contract.md`, `golden-renders.md` and `estate-lifecycle.md` point at `docs/contracts/component.md` instead of restating it; the Go cache section says ci-cache's `setup` wires the caches.
- README documents all seven reusable workflows with their consumers; private repository names, ticket keys and a real App id are gone from public text; the fleet workflows use the access-roster action at v1.39.1; `renovate.json` extends this repository's own preset.

## v3.13.1

2026-09-29.

- Renovate preset: the "0.x minors are breaking" rule matches Go's
  `v`-prefixed versions, and gomod updates run `go mod tidy`.

## v3.13.0

2026-09-26.

- `integration.yaml` has two tiers, picked from the calling repository's
  visibility: a disposable kind cluster on a hosted runner for a public
  repository (through ci-actions' `cluster`), the shared development
  cluster for a private one. A public caller asking for `tier: shared` is
  refused.
- Licensed MIT.

## v3.12.2

2026-09-24.

- `release-public.yaml`: helmctl 0.6.1, which gives a chart only its own
  images.

## v3.12.1

2026-09-24.

- `release-public.yaml`: `KO_DOCKER_REPO` follows `image-repo`, and
  `IMAGE_TAG` drops the `v`.

## v3.12.0

2026-09-24.

- `release-public.yaml`: packages charts from the images GoReleaser just
  pushed.

## v3.11.0

2026-09-24.

- `release-public.yaml`: a chart can be packaged from a release manifest,
  digest-pinned.
- Docs: a caller-parity kit can be a block inside a file.

## v3.10.0

2026-09-24.

- `release-public.yaml`: a chart need not live at the repository's root.

## v3.9.0

2026-09-24.

- The composite actions moved to
  [truvity/ci-actions](https://github.com/truvity/ci-actions), with their
  history and case harnesses; the workflows here pin them there.

## v3.8.0

2026-09-24.

- `setup-devbox` delegates the cache wiring to `truvity/ci-cache/setup`.

## v3.7.1

2026-09-23.

- Workflows pin `setup-devbox` at v3.7.0.

## v3.7.0

2026-09-23. The action only.

- `setup-devbox`: the Go cache agent sizes its own local budget.

## v3.6.1

2026-09-23.

- Workflows pin `setup-devbox` at v3.6.0.

## v3.6.0

2026-09-23. The action only.

- `setup-devbox`: the agent's local budget is capped and it reports
  metrics; the caller, not the workflow, passes `go-cache-server`.

## v3.5.1

2026-09-23.

- Workflows pin `setup-devbox` at v3.5.0.

## v3.5.0

2026-09-23.

- `setup-devbox`: a `go-cache-server` input and the agent that uses it
  (since retired: the input is ignored and warns).

## v3.4.0

2026-09-23.

- Every shared workflow refuses a self-hosted runner in a public
  repository.

## v3.3.0

2026-09-23.

- `public-runners` action: refuses a self-hosted runner in a public
  repository.
- `check.yaml` refuses a caller that pins an untagged ci-workflows
  commit.

## v3.2.0

2026-09-22.

- `tagged-pins` action: a ci-workflows pin must name a release.

## v3.1.2

2026-09-21.

- Docs: `auto-release`'s `token-source` default is documented as a
  default, not a recommendation.

## v3.1.1

2026-09-21.

- `caller-parity` cases cover the shapes a private estate's callers
  have.

## v3.1.0

2026-09-21.

- `caller-parity`: the shared caller workflows are compared against
  canonical kits, and reported.

## v3.0.2

2026-09-21.

- Every internal action pin is one release commit.

## v3.0.1

2026-09-21.

- Action pins bumped (renovate's proposal, minus the deleted files).

## v3.0.0

2026-09-21. **Breaking.**

- The per-repository `renovate.yaml`, `devbox-update.yaml` and
  `auto-approve.yaml` are gone; `renovate-fleet.yaml` and
  `parity-fleet.yaml` run them once per estate.

## v2.x and earlier

2026-08-16 to 2026-09-21: v1.0.0 to v2.29.0, 54 tags. GitHub releases,
with notes, exist for v1.0.0 to v2.6.0; after that, the tag messages and
`git log` are the record. In outline:

- v1.0.0: the five shared workflows. v1.1.0: a named step per recipe.
- v2.0.0: **one job per recipe** in `check.yaml` (breaking: status
  contexts became `<caller job> / <recipe>`). v2.1.x: per-recipe peak
  memory reporting. v2.2.0: the small-runner tier. v2.3.x and v2.4.0:
  private Go modules through a GitHub App token.
- Later v2.x: the medium-runner tier; opt-in npm cache wiring; the shared
  `auto-release.yaml` with its security lane, then tokens from
  access-roster instead of an App key; deterministic chart publishing
  through helmctl; the shared renovate preset (`default.json`); the
  reusable `integration.yaml`; `release-private.yaml` on the CI plane's
  warm builders; secrets read from OpenBao at run time; and
  `renovate-fleet.yaml` / `parity-fleet.yaml`, one job per estate.
