# A job's third-party secrets, read at run time

Credentials a job needs from somebody else — a licence key, a registry's
publishing token — are usually GitHub secrets: copied into every
repository and organization that builds, readable by every job that runs
there, and rotated by hand in as many places as hold a copy. Nothing says
which job may use one, because a secret in a repository is a secret for
every workflow in it.

[`openbao-secrets`](https://github.com/truvity/ci-actions/tree/master/openbao-secrets)
reads one path of secrets at run time, as the job itself, from an
OpenBAO KV v2 mount. Nothing is stored in the repository, and what a job
may read is decided outside it.

[`ssm-secrets`](https://github.com/truvity/ci-actions/tree/master/ssm-secrets)
does the same against AWS SSM Parameter Store and is the one to use for
new work: it needs no private endpoint, so any runner can reach it. The
OpenBAO sections below describe `openbao-secrets`, which stays for
callers that have not moved.

## Reading from SSM

```
the job's GitHub OIDC identity token
  → sluisctl token --audience aws:<account>:<role>   (exchanged at the issuer)
  → sts:AssumeRoleWithWebIdentity                    (the role's trust policy)
  → ssm:GetParametersByPath, decrypted, one level    (the role's policy)
```

The temporary credentials live in the action's own process; nothing is
written to an AWS config file or exported to a later step. The same three
things decide the outcome: the issuer's grants, the role's trust policy
and the role's policy.

```yaml
permissions:
  contents: read
  id-token: write # the read IS an exchange of the job's identity token

steps:
  - uses: truvity/ci-actions/setup-devbox@<sha>
    with: { github-token: "${{ secrets.GITHUB_TOKEN }}" }

  - uses: truvity/ci-actions/ssm-secrets@<sha>
    id: publish
    with:
      issuer: ${{ vars.ACCESS_ROSTER_ISSUER }}
      account: ${{ vars.CI_SECRETS_ACCOUNT }}
      role: ci-reader-example
      region: ${{ vars.CI_SECRETS_REGION }}
      path: /example/ci/publish
      keys: publish-username publish-password # empty takes every parameter under the path
```

The outputs are those of `openbao-secrets`: `value` when exactly one
parameter is taken, and `env-file`, one `NAME='value'` line per
parameter, the name being the parameter's last path segment upper-cased
with dashes turned into underscores (`publish-username` →
`PUBLISH_USERNAME`). Source the file as shown for `openbao-secrets`
below. A named key that is missing fails the step.

## The chain

```
the job's GitHub OIDC identity token
  → sluisctl token --audience <audience>       (exchanged at the issuer)
  → POST auth/<auth-mount>/login               (its groups → OpenBAO's)
  → GET  <mount>/data/<path>                   (what the policy admits)
  → POST auth/token/revoke-self
```

Three things decide the outcome, and none of them is in the workflow:

1. **The issuer's grants.** A job reaches the audience only if its
   identity — repository, ref, event and both workflow files, as GitHub's
   token states them — matches an identity the issuer declares.
2. **The login's role**, which maps the token's groups onto OpenBAO's
   identity groups.
3. **The policy** those groups carry: one path, read-only, is the shape
   to aim for.

So a workflow edit cannot widen what a job reads, and a job that is not
the one declared gets a refusal rather than a secret.

## Using it

```yaml
permissions:
  contents: read
  id-token: write # the read IS an exchange of the job's identity token

steps:
  - uses: truvity/ci-actions/setup-devbox@<sha>
    with: { github-token: "${{ secrets.GITHUB_TOKEN }}" }

  - uses: truvity/ci-actions/openbao-secrets@<sha>
    id: licence
    with:
      issuer: ${{ vars.ACCESS_ROSTER_ISSUER }}
      address: ${{ vars.CI_OPENBAO_ADDRESS }}
      namespace: ${{ vars.CI_OPENBAO_NAMESPACE }}
      ca-cert: ${{ vars.CI_OPENBAO_CA }}
      path: ci/goreleaser

  - name: Release
    env:
      GORELEASER_KEY: ${{ steps.licence.outputs.value }}
    run: devbox run -- goreleaser release
```

Several keys at once come back as a file instead, one
`NAME='value'` line per key, the name upper-cased with dashes turned into
underscores (`maven-username` → `MAVEN_USERNAME`):

```yaml
  - uses: truvity/ci-actions/openbao-secrets@<sha>
    id: publish
    with:
      issuer: ${{ vars.ACCESS_ROSTER_ISSUER }}
      address: ${{ vars.CI_OPENBAO_ADDRESS }}
      namespace: ${{ vars.CI_OPENBAO_NAMESPACE }}
      ca-cert: ${{ vars.CI_OPENBAO_CA }}
      path: ci/example-publish

  - name: Publish
    env:
      SECRETS: ${{ steps.publish.outputs.env-file }}
    run: |
      set -euo pipefail
      set -a; . "$SECRETS"; set +a
      devbox run -- ./publish
```

Every value is masked line by line before it is written anywhere, so a
multi-line secret is masked whole. The file is owner-only, lives under
`RUNNER_TEMP`, and dies with the ephemeral runner.

## What a caller needs

- **A self-hosted runner.** The address is normally a private endpoint;
  a GitHub-hosted runner cannot resolve it, and that is where the
  boundary sits.
- **`sluisctl` in the repository's devbox**, where its version is pinned
  beside the rest of the job's tools. `sluisctl: direct` takes it from
  the job's PATH instead.
- **`id-token: write`** on the job, granted by the workflow and by any
  caller of it.
- **Caller variables** for the issuer, the address, the namespace and —
  where the runner's trust store does not already cover the endpoint —
  the CA certificate. Never literals here: this repository is public.

## Through release-private.yaml

> **Deprecated.** A repository whose `.goreleaser.yaml` uses no Pro-only
> feature needs no licence: install the free goreleaser through the
> repository toolchain (devbox) and pass none of the goreleaser inputs
> or the `goreleaser-key` secret. This section stays for callers that
> still hold a licence; the inputs go in the next major release.

A private release does not need the step at all: the reusable workflow
reads the goreleaser-pro licence itself (parameter `goreleaser-key`,
exported as `GORELEASER_KEY`) when the caller names the account.

```yaml
    with:
      ssm-issuer: ${{ vars.ACCESS_ROSTER_ISSUER }}
      ssm-account: ${{ vars.CI_SECRETS_ACCOUNT }}
      ssm-region: ${{ vars.CI_SECRETS_REGION }}
      # goreleaser-secret-role defaults to ci-reader-goreleaser and
      # goreleaser-secret-path to /shared/internal/infra/ci/goreleaser
    secrets:
      goreleaser-key: ${{ secrets.GORELEASER_KEY }} # until a run has read the path
```

Without `ssm-account` the read is skipped and the secret is used. The
read is allowed to fail while both are set, and the secret stands behind
it. Drop the `secrets:` line once a release run shows the read
succeeded — the fallback then resolves to empty and the licence has one
home.

The `openbao-*` inputs and `goreleaser-licence-path` are still declared
so a caller that passes them does not break, but they are no longer read
(`openbao-issuer` still serves as the issuer when `ssm-issuer` is empty).
Remove them from the caller; they leave the workflow in a later release.

## Keeping the GitHub secret until it is proven

Move one consumer at a time, and keep passing the GitHub secret while
you do: a step that reads OpenBAO or SSM and a fallback to `secrets.X` live
together happily. Delete the secret only after a real run has read the
path — a deleted secret is a broken release, and the read is the only
proof that the identity, the policy and the value all line up.
