# Company repositories

A company that the platform serves keeps its own repositories, and each
one gates its pull requests with `check.yaml` alone. There is no
dispatch to a platform repository, no `actions: write` grant to grant,
and no token that can reach anything but what the pull request itself
can. This page says what the gate checks, what a company sets up, and
what is not built yet.

## Two kinds

| kind | what it holds | `company-kind` | template |
| -- | -- | -- | -- |
| configuration | the company's authored configuration (a `tenant/` tree) and, for objects the company owns, its own infrastructure code | `config` | [`templates/company/config`](../templates/company/config) |
| delivery | release pins and values: `pins/<service>/<cluster>.yaml` and `values/<service>/<cluster>.yaml`, and nothing of the platform | `delivery` | [`templates/company/delivery`](../templates/company/delivery) |

Each template is the repository's `.github/workflows/check.yaml`, and a
`Justfile` with the `chart-gate` recipe below. Copy the caller verbatim into a new
repository. It is the same file in every company; the company's own
settings are repository variables:

| variable | meaning |
| -- | -- |
| `TENANT_INPUTS` | the digest-pinned artifact in which the platform publishes this company's non-secret inputs, `<registry>/<name>@sha256:<hex>` |
| `CHART_PROFILE` | the `aws:<account>:<role>` audience of a role that can read the company's private charts and nothing else |
| `CHART_REGISTRY` | the registry host that credential is for |
| `ACCESS_ROSTER_ISSUER` | the roster issuer the audience is exchanged at |
| `COMPANY_FORBIDDEN_IMPORT_PREFIXES` | for a `config` repository, the Go module path prefixes it must not import, require or vendor; empty switches those rules off |

The templates are held to the
[truvity/ci-actions](https://github.com/truvity/ci-actions) caller-parity
kits by `hack/templates-cases.sh`, so the parity report and the template
cannot disagree.

## What the gate does

The caller passes `company-kind`. `check.yaml` then runs two jobs beside
`pins`; with `company-kind` empty, the default, it runs neither and every
other job is what it was.

1. **`company-boundary`** judges the checkout offline: no network call, no
   repository code run, no symlink followed. It is a deny-list, not a path
   allow-list, so a runbook, a `Justfile` or validation tooling passes. Both
   kinds refuse an Argo CD or Kargo object, a Namespace, a Secret that
   carries data, a symlink that leaves the tree, a Go `replace` directive
   and, for the prefixes the company passes
   (`COMPANY_FORBIDDEN_IMPORT_PREFIXES`), an import, a requirement or a
   vendored copy. A `delivery` repository also refuses an infrastructure project (`Pulumi.yaml` and its
   stack files) and a `tenant/` tree, and holds `pins/` to `pins:` mapping
   names to string versions (the empty string means dormant) and `values/`
   to `values:`. A refusal is one line,
   `company-boundary: <kind>: <path>: <rule>`; the rules are in
   [truvity/ci-actions](https://github.com/truvity/ci-actions)
   `company-boundary`.
2. **`company-validate`** runs after the boundary. It fetches the
   `TENANT_INPUTS` artifact read-only, by digest, into a directory outside
   the workspace; a tag, a tag with a digest, or bytes that do not match
   the digest are refused, and a copy committed in the repository is never
   read. With `CHART_PROFILE` it exchanges the job's own identity token for
   the chart-read role and logs in to the registry, refusing any long-lived
   AWS key. Then it validates the tenant bundle and runs the company's
   chart recipe, when asked.

Two inputs of `check.yaml` switch those on:

- `tenant-validate` validates the `tenant/` directory of a `config`
  repository with the validator of
  [truvity/policy](https://github.com/truvity/policy), the
  `tenant-validate` command. The workflow builds it from the module at a
  version it pins (`POLICY_VERSION`, which renovate moves), with `go
  install`, from outside the checkout: the Go checksum database vouches for
  the bytes, and nothing of the candidate is built or run, only read. It
  runs before the chart login, so it never sees that credential. The
  command loads the bundle and validates it (the files it may hold, their
  shapes and schemas, every refusal with its stable code) and prints the
  company and the bundle's pin. Exit status 1 is a refused bundle, every
  failure printed one per line, and 2 a check that could not run; both fail
  the job. It fails too when the repository has no `tenant/` directory, when
  it is a link, and when the repository is a `delivery` one, which holds no
  bundle: a validation that would check nothing is not a pass. The input
  needs `tenant-inputs`; asking for it without fails the job.
- `chart-gate` runs the company's `chart-gate` recipe with the registry
  login exported (`DOCKER_CONFIG`, `HELM_REGISTRY_CONFIG`). The recipe stays
  in the company's `Justfile`, which keeps `check.yaml` independent of the
  chart gate's version.

Both inputs default to false, and the caller template passes neither: the
caller is copied verbatim and held to the caller-parity kit, so a company
cannot switch a validation on by editing its own copy (that would show as
drift in the parity report). Turning one on is a change to the kit in the
[truvity/ci-actions](https://github.com/truvity/ci-actions) repository
first, and then to the template here, together; every company's copy then
moves with them. Asking for a validation without its input (`tenant-validate`
without `tenant-inputs`, `chart-gate` without `chart-profile`) fails the
job.

### What a green run did not validate

The job ends with a step that says what its green does not mean, as a
notice annotation and a line of the step summary for each, on every run:

- `tenant-validate` off: no tenant bundle was validated.
- `tenant-validate` on: the bundle was not checked against the platform's
  record of the company (its zones, e-mail domains, registries and
  ceilings). The platform runs that when it takes the bundle: a company's
  repository does not hold the record. The fetched `tenant-inputs` were not
  read either: the validator takes the bundle alone.
- `chart-gate` off: no chart was gated. On: the company's own recipe ran,
  and no validator of the platform's stands behind it yet.
- A `delivery` repository: `pins/` and `values/` were judged by the
  boundary's shape rules only, and no validator reads their content.

`hack/tenant-validate-cases.sh` proves the validation step: it builds the
pinned validator the way the job does, runs the step on acme and globex
bundles (one accepted, two refused, and a missing, a linked and a wrong-kind
`tenant/`), and removes the call to the validator and each rule of the step
in turn, which must turn a case red. It cannot run GitHub parsing the call,
the fetch of the inputs artifact or the chart login; `hack/company-cases.sh`
holds the wiring around the step.

## Pull requests from forks

Both jobs fail, they do not skip, for a pull request from a fork, for a
pull request whose head repository is gone, and for `pull_request_target`.
A skipped required check reads as green, so a skip would be a hole. The
caller triggers on `pull_request`, so a candidate runs with the read-only
token of its own pull request, and a contributor works from a branch of the
company's repository.

The caller grants `contents: read`, and `id-token: write` for the chart
login.

## The caller is a fan-in

A reusable workflow cannot supply the status context that a branch ruleset
requires, so the template has a job named `check` that needs the call and
is strict: `success`, nothing else. The ruleset requires `check`.

## Not built yet

- **The registration check.** `tenant-validate` checks the bundle alone. The
  comparison with the platform's record of the company is the platform's
  and has no command a company's CI can run, so the fetched `tenant-inputs`
  are not compared with the bundle, and a green run says so.
- **`chart-gate` waits for a chart gate that takes explicit inputs.** It
  stays a stub in the templates' `Justfile`, which fails on purpose, and
  off by default.
- **The inputs artifact is fetched by digest.** `TENANT_INPUTS` carries the
  digest. Resolving a moving tag and verifying its signature is a separate
  step that does not exist yet; the variable's meaning changes with it.
  The fetch is anonymous: a registry that wants a credential is not served.
- **No caller switches `tenant-validate` on yet.** The kit in
  truvity/ci-actions passes neither input. It gains `tenant-validate: true`
  for a `config` repository first, then the template follows it.
- **The templates pin v6.2.0**, which predates these inputs, as the
  caller-parity kits do. Move the pin to the first release that carries the
  validation wiring (the CHANGELOG says which); nothing else in the file
  changes except what the kit changes.
- **No fleet template.** Dependency updates and version parity for a
  company are not part of this gate.
