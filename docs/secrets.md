# A job's third-party secrets, read at run time

Credentials a job needs from somebody else — a licence key, a registry's
publishing token — are usually GitHub secrets: copied into every
repository and organization that builds, readable by every job that runs
there, and rotated by hand in as many places as hold a copy. Nothing says
which job may use one, because a secret in a repository is a secret for
every workflow in it.

[`ssm-secrets`](https://github.com/truvity/ci-actions/tree/master/ssm-secrets)
reads one path of secrets at run time, as the job itself, from AWS SSM
Parameter Store. Nothing is stored in the repository, and what a job may
read is decided outside it. It needs no private endpoint, so any runner
can reach it.

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

The outputs are `value` when exactly one parameter is taken, and
`env-file`, one `NAME='value'` line per parameter, the name being the
parameter's last path segment upper-cased with dashes turned into
underscores (`publish-username` → `PUBLISH_USERNAME`). A named key that
is missing fails the step. Source the file in the step that needs it:

```yaml
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

- **`sluisctl` in the repository's devbox**, where its version is pinned
  beside the rest of the job's tools. `sluisctl: direct` takes it from
  the job's PATH instead.
- **`id-token: write`** on the job, granted by the workflow and by any
  caller of it.
- **Caller variables** for the issuer, the account and the region. Never
  literals here: this repository is public.

## Keeping the GitHub secret until it is proven

Move one consumer at a time, and keep passing the GitHub secret while
you do: a step that reads SSM and a fallback to `secrets.X` live
together happily. Delete the secret only after a real run has read the
path — a deleted secret is a broken release, and the read is the only
proof that the identity, the policy and the value all line up.
