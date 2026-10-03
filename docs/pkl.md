# Pkl contracts

Two things serve a library of Pkl contracts and the repositories that consume
it: a check for the repository that authors the contracts, and a fleet job
that moves its consumers to each release. The packaging itself is
[`release-pkl.yaml`](../.github/workflows/release-pkl.yaml).

## Checking a repository that authors contracts

There is no workflow for this, on purpose. [`check.yaml`](../.github/workflows/check.yaml)
already runs the caller's own `just` recipes, one parallel job each, inside
its devbox, and fails a recipe that leaves the working tree modified. That is
the whole of what a producer check needs:

| check | recipe | how `check.yaml` enforces it |
|---|---|---|
| regenerate, and the committed artifacts are current | `generate` (rewrites the committed files) | the tree is modified, or has new untracked files, so the job fails. This is `git diff --exit-code` plus the untracked files it misses. A recipe that regenerates into a temporary directory and compares (`generated`) works too |
| validate the examples in every language | `conformance`, or whatever runs every validator over the fixtures | the recipe's exit status |
| no undeclared breaking change against the last release tag | `compat` | the recipe's exit status. The rule (which changes are breaking, and how a breaking one is declared) stays in the repository's own recipe, where it can be tested with the contracts |

```yaml
jobs:
  recipes:
    uses: truvity/ci-workflows/.github/workflows/check.yaml@<sha> # vX.Y.Z
    with:
      recipes: '["test", "lint", "generate", "conformance", "compat"]'
      # `compat` reads the last release tag. A recipe that fetches the tag
      # itself needs nothing more; one that walks history wants:
      # fetch-depth: 0
```

A separate `pkl-producer.yaml` would add only a `pkl-command` input and a
fixed order of steps, and would own a rule (what a breaking change is) that
belongs to each repository's recipe. Pkl itself comes from the repository's
devbox, or from a `bin/pkl` the recipes call; neither is a workflow concern.

## `pkl-fleet`: consumers follow each release

A consumer declares the packages in a `PklProject` and commits the
`PklProject.deps.json` that records their checksums. Renovate has no Pkl
manager and cannot regenerate `deps.json`, so
[`pkl-fleet.yaml`](../.github/workflows/pkl-fleet.yaml) does what a person
would, once per consuming repository: rewrite the URIs to the new release, run
`pkl project resolve`, run the repository's `generate` recipe, open a pull
request.

```
package://github.com/<owner>/<repo>/releases/download/v<ver>/<name>@<ver>      PklProject
package://github.com/<owner>/<repo>/releases/download/v<ver>/<name>@<major>    deps.json key
projectpackage://github.com/<owner>/<repo>/releases/download/v<ver>/<name>@<ver>   deps.json uri
```

### Discovery

The estate's enrolment list is the scope, as for the other fleet jobs
([fleet.md](fleet.md)): list the repositories under a name such as `pkl.public`
in the caller's `fleet.yaml`. `fleet-discover` applies its usual rules
(archived repositories out, the App's reach checked, a required status check
demanded). The job then reads each remaining repository's default-branch tree
for `PklProject` files, reads each, and keeps only those with a dependency URI
into `source` that is not already at the target version. A repository that is
current costs a tree read and no runner.

Code search was not used: it is rate-limited, eventually consistent and a
second notion of scope beside the enrolment list. A repository with a
`PklProject` into the library but no `devbox.json` is an error annotation: the
job runs its recipes in its devbox.

### What a job does

1. Rewrites every `PklProject` and `PklProject.deps.json` naming `source` to
   the target version. Before it writes anything it refuses a URI under
   `source` that is not `v<version>/<name>@<version>` (or the major-only key),
   a tag and package version that disagree, and a downgrade.
2. Runs the repository's `resolve` recipe when it has one, else
   `pkl-command project resolve <dir>` for each rewritten project, then its
   `generate` recipe when it has one, all inside its devbox.
3. Commits, force-pushes `pkl-contracts-<version>` only if the content
   differs from that branch, and opens or updates one pull request labelled
   `dependencies`. An open pull request for an older version is closed as
   superseded.

Auto-merge (rebase) is armed only for a bump that is not breaking and only
with `require-check` on. Breaking means a new major, a new minor while the
major is 0, or a prerelease target; such a pull request carries `major`, which
the fleet's approval step never approves, and is left for a human.

Module files that import a package by a `package://` URI of their own are not
rewritten: only `PklProject` and `PklProject.deps.json` are.

### Calling it

Poll rather than dispatch. A `repository_dispatch` from the library's release
workflow into the caller would need a token, held by the library's repository,
that can write to the caller. A schedule needs nothing from the library, an
idle run is a few API reads, and the latency is the period.

```yaml
# .github/workflows/pkl.yaml in the caller repository
name: pkl
on:
  schedule:
    - cron: "17 * * * *"
  workflow_dispatch:
    inputs:
      version:
        description: Release to move to (empty: the latest)
        default: ""
      dry-run:
        description: Rewrite and resolve, open nothing
        type: boolean
        default: false
concurrency:
  group: pkl
  cancel-in-progress: false
permissions:
  contents: read
  id-token: write
jobs:
  pkl:
    uses: truvity/ci-workflows/.github/workflows/pkl-fleet.yaml@<sha> # vX.Y.Z
    with:
      estate: public
      list: pkl.public
      version: ${{ inputs.version || '' }}
      dry-run: ${{ inputs.dry-run || false }}
      token-source: access-roster
      access-roster-issuer: https://access.example
      github-app: renovate-public
      git-user: example-renovate-public[bot]
```

```yaml
# fleet.yaml
pkl:
  public: [some-consumer, another-consumer]
```

With a key instead: `client-id` and the `RENOVATE_APP_PRIVATE_KEY` secret
replace `token-source`, `access-roster-issuer` and `github-app`.

The App needs `contents: write` and `pull_requests: write` on each consumer
(read-only on a dry run), which the App `parity-fleet` uses already has. Run a
dry run first.
