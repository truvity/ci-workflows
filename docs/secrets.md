# A job's third-party secrets, read at run time

Credentials a job needs from somebody else — a licence key, a registry's
publishing token — are usually GitHub secrets: copied into every
repository and organization that builds, readable by every job that runs
there, and rotated by hand in as many places as hold a copy. Nothing says
which job may use one, because a secret in a repository is a secret for
every workflow in it.

`.github/actions/openbao-secrets` reads one path of secrets at run time,
as the job itself, from an OpenBAO KV v2 mount. Nothing is stored in the
repository, and what a job may read is decided outside it.

## The chain

```
the job's GitHub OIDC identity token
  → accessctl token --audience <audience>      (exchanged at the issuer)
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
  - uses: truvity/ci-workflows/.github/actions/setup-devbox@<sha>
    with: { github-token: "${{ secrets.GITHUB_TOKEN }}" }

  - uses: truvity/ci-workflows/.github/actions/openbao-secrets@<sha>
    id: licence
    with:
      issuer: ${{ vars.CI_ACCESS_ROSTER_ISSUER }}
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
  - uses: truvity/ci-workflows/.github/actions/openbao-secrets@<sha>
    id: publish
    with:
      issuer: ${{ vars.CI_ACCESS_ROSTER_ISSUER }}
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
- **`accessctl` in the repository's devbox**, where its version is pinned
  beside the rest of the job's tools. `accessctl: direct` takes it from
  the job's PATH instead.
- **`id-token: write`** on the job, granted by the workflow and by any
  caller of it.
- **Caller variables** for the issuer, the address, the namespace and —
  where the runner's trust store does not already cover the endpoint —
  the CA certificate. Never literals here: this repository is public.

## Keeping the GitHub secret until it is proven

Move one consumer at a time, and keep passing the GitHub secret while
you do: a step that reads OpenBAO and a fallback to `secrets.X` live
together happily. Delete the secret only after a real run has read the
path — a deleted secret is a broken release, and the read is the only
proof that the identity, the policy and the value all line up.
