# Changelog

Every release of truvity/ci-workflows, newest first. Pin the commit of a
tag (`git rev-parse vX.Y.Z^{commit}`), with the version in a trailing
comment. Entries from v3.0.0 to v3.13.1 are reconstructed from `git log`:
those tags have no GitHub release; v3.14.0 on do.

## Unreleased

- `just pins` and the README consumer table no longer list the archived truvity/ci-cache.

## v3.26.0

- Every `truvity/ci-actions/setup-devbox` pin moves to v1.15.0, which calls the in-repo `setup-cache` action instead of `truvity/ci-cache/setup@v0.2.0`. No other workflow change; the cache wiring is the ci-cache v0.3.1 action, moved. After this, no workflow here reaches truvity/ci-cache.

- `pkl-fleet.yaml`: the discover job's "Resolve the target version" and "Find the consumers that need a bump" (about 80 lines of curl and jq) are the `truvity/ci-actions/pkl-fleet` action (`step: target|consumers`), the last shell blocks of the workflow. Same inputs, outputs (`version`, `repositories`, `count`), log lines, annotations and API calls; `hack/pkl-fleet-cases.sh` keeps only the setup-devbox wiring assertion, the cases are Go tests in ci-actions.

- `pkl-fleet.yaml`: the dependency-URI rewrite, the resolve-and-regenerate step and the pull-request step (about 235 lines of shell, curl and jq) are the `truvity/ci-actions/pkl-fleet` action (`step: rewrite|resolve|publish`), and the commit-author lookup is `truvity/ci-actions/fleet-step`. Same inputs and outputs (`changed`, `breaking`, `from`, `url`), same refusals, API calls and pull-request text; their cases moved from `hack/pkl-fleet-cases.sh` to Go tests in ci-actions, which keeps only the target-version and consumer-discovery cases.

- `parity-fleet.yaml` and `renovate-fleet.yaml`: the small shell steps (print the job's OIDC claims in both discover jobs, the commit-author lookup, the default branch and parity settings read, the renovate approval, the available-majors table; about 150 lines of curl and jq) are the `truvity/ci-actions/fleet-step` action, one `step` each. Same step names, ids, outputs (`git-email`, `base`, `module-dirs`, `mode`), log lines, annotations and summary.

- `release-pkl.yaml`: the five shell steps (declared version, tag and changelog checks, asset checks, publish, smoke test; about 190 lines) are the `truvity/ci-actions/release-pkl` action, one `step` each. Same inputs, same outputs (`version`), same refusal texts and behaviour; `hack/release-pkl-cases.sh` is removed, its cases are Go tests in ci-actions.

- `release-private.yaml`: the "Require green checks on the tagged commit" step (102 lines of curl and jq, with an embedded self-test) is the `truvity/ci-actions/require-green-checks` action. Same rule, same log lines and `::error::` text, same exit status; it reads the API itself, so neither `curl` nor `jq` is needed on the runner for it.

- `parity-fleet`, `renovate-fleet`, `pkl-fleet` and `auto-release`: the inline token-input check (four copies) is the `truvity/ci-actions/token-inputs` action, and the inline enrolment-list read (four copies, `yq` and `jq`) is `truvity/ci-actions/enrolment-list`, both pinned at ci-actions v1.10.0. Same messages, same order, same exit status, same `names` output. Only a plain dotted `list` path is read now (no `yq` expression syntax), and `yq` and `jq` are no longer needed on the runner for it.

- `release-public.yaml`: the "Package and push charts" step (a 109-line embedded Python resolver and helmctl loop) is the `truvity/ci-actions/publish-charts` action. Same `charts`, `chart-root`, `chart-registry`, `chart-app-version`, `chart-images` and `require-image-digests` inputs, same refusal messages, same helmctl calls; `python3` is no longer needed on the runner for it.

- `parity-fleet`, `renovate-fleet`, `pkl-fleet` and `auto-release`: the inline token-input check (four copies) is the `truvity/ci-actions/token-inputs` action, and the inline enrolment-list read (four copies, `yq` and `jq`) is `truvity/ci-actions/enrolment-list`, both pinned at ci-actions v1.10.0. Same messages, same order, same exit status, same `names` output. Only a plain dotted `list` path is read now (no `yq` expression syntax), and `yq` and `jq` are no longer needed on the runner for it.

- `release-public.yaml`: the "Publish Nix flakes" step (a 149-line Python generator and nix loop) is the `truvity/ci-actions/publish-nix-flakes` action. The generated `flake.nix` is byte-identical, as are the uploaded asset names and the deterministic packing; `python3` is no longer needed on the runner for it.

- `parity-fleet`, `renovate-fleet`, `pkl-fleet` and `auto-release`: the inline token-input check (four copies) is the `truvity/ci-actions/token-inputs` action, and the inline enrolment-list read (four copies, `yq` and `jq`) is `truvity/ci-actions/enrolment-list`, both pinned at ci-actions v1.10.0. Same messages, same order, same exit status, same `names` output. Only a plain dotted `list` path is read now (no `yq` expression syntax), and `yq` and `jq` are no longer needed on the runner for it.

- `auto-release.yaml`: the release gate and the next-patch-tag step (each in two jobs) are the `truvity/ci-actions/auto-release` action (`step: gate` and `step: tag`) instead of inline shell. Same inputs, same `skip` output, same behaviour; its cases moved from `hack/auto-release-cases.sh` (removed) to Go tests in ci-actions.

- `parity-fleet`, `renovate-fleet`, `pkl-fleet` and `auto-release`: the inline token-input check (four copies) is the `truvity/ci-actions/token-inputs` action, and the inline enrolment-list read (four copies, `yq` and `jq`) is `truvity/ci-actions/enrolment-list`, both pinned at ci-actions v1.10.0. Same messages, same order, same exit status, same `names` output. Only a plain dotted `list` path is read now (no `yq` expression syntax), and `yq` and `jq` are no longer needed on the runner for it.

## v3.25.0

- The token exchange in `auto-release.yaml`, `parity-fleet.yaml`, `pkl-fleet.yaml` and `renovate-fleet.yaml` is `truvity/ci-actions/token-exchange` (pinned at v1.9.0) instead of the `truvity/access-roster` root action, so no reusable workflow references access-roster as an action. Same inputs and outputs.
- `release-private.yaml`: the ARC builder registration step is the `truvity/ci-actions/setup-remote-builders` action (pinned at v1.8.0, as `integration.yaml` already does) instead of an inline copy of its shell. Same input (`remote-builders`), same builder name (`ci`), same `BUILDX_BUILDER` export; the only visible difference is the wording of the error for an empty `remote-builders`.

## v3.24.1

- `release-pkl.yaml`: the smoke test now retries with exponential backoff, sleeping 10, 15, 20, 30, 45, 60, 60, 60 seconds (approximately 5 minutes total) instead of a constant 10 seconds 5 times, to account for CDN propagation delays when release assets are just published.

## v3.24.0

- New `pkl-fleet.yaml`: moves every consumer of a Pkl contracts library to its newest release, from one caller, as a matrix job per repository. Discovery is the fleet's (an enrolment list and `fleet-discover`), narrowed to repositories whose `PklProject` files hold a dependency URI into `source` (default `truvity/pkl-contracts`) that is not already at the target, so a run with nothing to do starts no runner. Each job rewrites the `package://` and `projectpackage://` URIs in every `PklProject` and `PklProject.deps.json` (the full-version and major-only `@<major>` forms), refusing before it writes on a URI it cannot read, a tag and package version that disagree, or a downgrade; runs the repository's `resolve` recipe (else `pkl-command project resolve` per project) and its `generate` recipe inside its devbox; and opens or updates one pull request on `<branch-prefix><version>` (default `pkl-contracts-<version>`), labelled `dependencies`, force-pushing only when the content changed and closing an older version's pull request as superseded. Auto-merge (rebase) is armed only for a bump that is not breaking (a new major, a new minor while the major is 0, or a prerelease target are breaking and carry `major`) and only with `require-check`. Inputs: `version` (empty: the latest release, which must be published), `dry-run` (read-only tokens, opens nothing), `auto-merge`, `source`, `branch-prefix`, `pkl-command`, and the token inputs of `parity-fleet`. The App needs `contents: write` and `pull_requests: write` on the consumers, as `parity-fleet` does. `hack/pkl-fleet-cases.sh` runs the blocks against stubbed `curl`, `devbox`, `just` and Pkl and a local git remote, and runs in `self-check` and `just check`.
- `docs/pkl.md`: a repository that authors Pkl contracts is checked with `check.yaml` and its own recipes (regenerate and require a clean tree, validate, compare with the last release), with no workflow of its own; the page maps the three checks to recipes and shows the caller, and documents `pkl-fleet` and how a caller triggers it.

## v3.23.0

- `auto-release.yaml` takes an optional `version-bump-command` for a repository that declares its version in files. It is a shell command run in the caller's checkout, inside devbox (set up with the pinned `setup-devbox` only when the input is set), with `VERSION` (`X.Y.Z`) and `TAG` (`vX.Y.Z`) in its environment. It runs after the CHANGELOG heading is written and before the commit, so the heading pull request carries the bump and the tag names the merge commit that has both; a bump that changes nothing fails the run. A resumed open heading PR is not bumped again, and a heading that already exists (a person prepared that release) is tagged as it stands. With a bump set, a dependency-only patch also gets its heading pull request, and `changelog-heading: never` is refused. The header carries an example caller for a Pkl repository. An empty input (the default) is today's behaviour exactly; `hack/auto-release-cases.sh` covers the bump, the empty bump, the resume and the refusals.

## v3.22.0

- New `release-pkl.yaml`: releases a repository's Pkl packages as GitHub Release assets, on a tag. It reads the declared version with the caller's `version-command` (empty: the tag is the version) and refuses unless the tag is `v` plus it and the CHANGELOG has a `## vX.Y.Z` heading; runs the caller's `just` recipe (`package-recipe`, default `package`); checks that every file under `output-dir` (default `.out`) is named for `@<version>` and has a matching `.sha256`; creates the release with the CHANGELOG section as notes and uploads every asset under its exact name, `@` included; then resolves the packages from github.com with `pkl-command` (and imports the modules named by `smoke-import`) against a fresh cache. A re-run completes a release that is missing assets and refuses one that holds an asset the build does not produce or one with different bytes. The caller grants `contents: write`. `hack/release-pkl-cases.sh` runs the checks, the publish step and the smoke test as written, against a stubbed `gh` and Pkl, and runs in `self-check` and `just check`.

## v3.21.0

- Every `truvity/ci-actions` pin moves from v1.7.0 to v1.8.0, which moves each action's logic into the `ci-actions` Go binary behind thin composites. The inputs and outputs the workflows use are unchanged. What a caller's runner needs changes: the first step of every action job fetches the checksum-verified release binary, so the runner needs `curl`, `tar` and `sha256sum` (or Go). `setup-devbox` installs devbox, when the runner does not bake it, into `$RUNNER_TEMP/bin` (on `PATH`) rather than `/usr/local/bin`, verified against the release checksums; a step that ran `/usr/local/bin/devbox` by absolute path must use `devbox` from `PATH`. `fleet-discover` now warns when `filter` is not a valid expression, and `caller-parity` treats a `kits.yaml` that is not valid YAML as an error.

## v3.20.0

- `release-public.yaml` can push a web application's JavaScript source maps with `smctl` (truvity/ocictl, pinned) right after GoReleaser, in the same job: new inputs `sourcemaps-image` (the GoReleaser image whose maps to push; empty, the default, is off), `sourcemaps-dir` (default `dist-sourcemaps`) and `sourcemaps-app` (the `{app}` of the repository when the image is named differently from the application, e.g. image `web` for `url-shortener`; empty, the default, is the image's last path segment). The version and registry come from `dist/`, so maps exist only for a version whose image was published, from the same build, and a failed push fails the release. The artifact lands in `{registry}/{owner}/sourcemaps/{app}` tagged with the version. No new permission: the `packages: write` callers already grant covers the push. Callers that leave `sourcemaps-image` empty are unchanged.
- `release-public.yaml` packages charts with helmctl 0.8.0 (was 0.6.1). A chart whose `Chart.yaml` `dependencies:` are not all present in `charts/` (a `file://` library chart in the same repository, or an `oci://`/`https://` one) has them resolved with `helm dependency build` before packaging, honouring a committed `Chart.lock`. A chart that commits its dependency archives and `Chart.lock` packages exactly as before: no dependency step, no network, the same bytes. Under `require-image-digests: true` the dependencies' `images:` must carry digests too.

## v3.19.0

- `release-public.yaml`'s `charts` input accepts a **repository-root path** beside the plain names it always took. An entry containing a `/` (`charts/service-lib`) is a path from the repository root: `chart-root` does not apply to it, so a chart that lives somewhere other than `chart-root` is published by the same call, under the same tag, as the ones that do. It is packaged, pushed and named by the last element of its path. A plain entry behaves exactly as before. A path that is absolute, has an empty, `.` or `..` element, or whose name is not a lowercase chart name is refused before anything is built, and so are two entries with the same last element. `hack/chart-paths-cases.sh` runs the resolution as written in the workflow, and runs in `self-check`.
- Every `truvity/ci-actions` pin moves from v1.6.1 to v1.7.0. No action asks for privilege any more: no root, no `sudo`, so the reusable workflows run unchanged on a runner under the Pod Security `restricted` profile. The inputs the workflows pass are unchanged.
- `setup-devbox` starts with a `preflight` step that prints the uid, whether `no_new_privs` is set, what `/bin/sh` is, and whether `HOME`, `RUNNER_TEMP` and the work directory are writable, and fails early with one message naming what is missing.
- `policy-conformance` C1 accepts a declared mirror chart: a chart that republishes a third-party artifact unchanged declares `annotations: {truvity.io/mirror: "<owner>/<repo>@<version>"}` in `Chart.yaml`, and its `version` (and `appVersion`, when present) must then equal that `<version>` instead of `0.0.0`.
- `tagged-pins` and `public-runners` run the `ci-actions` binary (the checksum-verified release archive of the pinned tag, or one on `PATH`, or a Go build); inputs, log lines and exit status are unchanged, and the runner needs curl and tar or Go.
- **Behaviour change for callers on GitHub-hosted runners:** `setup-devbox` no longer relinks `/bin/sh` to bash, so on a hosted runner `/bin/sh` stays dash. A `run:` step outside `devbox run` that needs bash semantics (`[[ ]]`, arrays, `pipefail`) must set `shell: bash` or `defaults.run.shell: bash`, and a Justfile whose recipes need bash should `set shell := ["bash", "-euo", "pipefail", "-c"]`. Inside `devbox run`, `sh` is bash already, so devbox scripts and `just` recipes are unaffected.

## v3.18.1

- Every `truvity/ci-actions` pin moves from v1.5.0 to v1.6.1. Its `setup-devbox` tolerates `no_new_privs`, so the reusable workflows run on non-root (Pod Security `restricted`) runners.

## v3.18.0

- `auto-release.yaml` writes the CHANGELOG heading itself before it tags, so a patch it cuts never leaves shipped changes under `## Unreleased`. A first `## Unreleased` with entries becomes `## vX.Y.Z` (dated only where the newest heading is); a dependency-only patch gets `## vX.Y.Z` with "Dependency updates." only where the newest patch tag has its own heading, and otherwise relies on C5's automatic-patch case. The heading goes in by a pull request the job arms for auto-merge, and the tag names the merged commit. A PR titled `docs(changelog): heading for the vX.Y.0 release` makes the job stand aside; a heading already present is never rewritten. New inputs `changelog-heading` (`auto`, `always`, `never`), `changelog-path` and `changelog-wait-minutes`. **Before a caller moves to this version** its issuer grant for the tagging App must carry `pull_requests: write` (the job now asks for it, except under `changelog-heading: never`), and the repository's auto-merge setting must be on; a key-held App needs the same permission. A repository whose ruleset wants an approval on the heading PR will see the run wait and fail red until someone approves; set `changelog-heading: never` there.
- `hack/auto-release-cases.sh` runs the tagging step against a real git repository and a stubbed `gh`: heading rename, dated headings, dependency-only patches, opt-out, an open release PR, a PR that never merges and is resumed, and an existing heading.

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
