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
`Justfile` with the two recipes below. Copy the caller verbatim into a new
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
   carries data, and a symlink that leaves the tree. A `config` repository
   also refuses a Go `replace` directive and, for the prefixes the company
   passes, an import, a requirement or a vendored copy. A `delivery`
   repository also refuses an infrastructure project (`Pulumi.yaml` and its
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
   AWS key. Then it runs the company's recipes when asked.

The recipes stay in the company's `Justfile`, which keeps `check.yaml`
independent of any validator's version:

- `tenant-validate` validates the candidate against the fetched inputs
  (`TENANT_INPUTS_DIR`). Switched on with the `tenant-validate` input.
- `chart-gate` gates the candidate's charts with the registry login
  exported. Switched on with the `chart-gate` input.

Asking for a recipe without its input (`tenant-validate` without
`TENANT_INPUTS`, `chart-gate` without `CHART_PROFILE`) fails the job.

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

- **`tenant-validate` is a stub.** The input defaults to false because the
  validator it calls is not released. The template recipe fails on purpose
  until it is replaced, so that switching the input on early reads as a
  failure, not as a gate that passed.
- **`chart-gate` waits for a chart gate that takes explicit inputs.** Same
  default, same stub.
- **The inputs artifact is fetched by digest.** `TENANT_INPUTS` carries the
  digest. Resolving a moving tag and verifying its signature is a separate
  step that does not exist yet; the variable's meaning changes with it.
  The fetch is anonymous: a registry that wants a credential is not served.
- **The templates pin v6.2.0**, which predates these inputs, as the
  caller-parity kits do. Move the pin to the first release whose changelog
  names `company-kind`; nothing else in the file changes.
- **No fleet template.** Dependency updates and version parity for a
  company are not part of this gate.
