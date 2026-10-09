# The two integration tiers

`integration.yaml` runs a caller's suites on one of two tiers. A caller
never picks the tier by hand-wiring runners or a cluster — it names its
lanes and its inputs, and the workflow decides the tier for it.

## Why tier follows visibility, not the caller

```
github.event.repository.visibility == public  ->  kind
otherwise                                      ->  shared
```

A **public** repository's pull requests come from forks. A fork's code
must never execute on the estate's own runners, reach the estate's
development cluster, or spend the estate's credentials — the same rule
`public-runners` already enforces for `check.yaml`. So a public caller
gets a disposable cluster on a GitHub-hosted runner: nothing it stands up
survives the job, and nothing it touches belongs to the estate.

A **private** repository's suites keep running exactly as they always
have: the estate's own runners, against the estate's own development
cluster, with the estate's credentials exchanged through `sluisctl`.

The `tier` input lets a caller override this in ONE direction only: a
private repository may ask for `tier: kind` (proving the public path
locally, or simply not needing the shared tenant for a given suite). A
public repository asking for `tier: shared` is refused before anything
else runs — visibility is read from the event payload, not trusted from
an input, so a caller cannot spell its way out of the refusal.

## The kind tier, mechanically

[`truvity/ci-actions`](https://github.com/truvity/ci-actions)' `cluster`
action, `mode: kind`, fetches
[`truvity/policy`](https://github.com/truvity/policy)'s `hack/kind/` box
at a pinned release tag (the caller's `policy-version` input) and runs
it: `kind create cluster`, the servers the box provides (a database
operator, a message broker, an S3 stand-in — see the box's own
`hack/kind/README.md`), and a local registry, all inside the one
GitHub-hosted runner. The box is fetched from a release tarball rather
than vendored here, so a change to it ships through policy's own
release, never through a second copy kept in sync by hand.

It starts in the **background**, launched right before the lane's Build
step: the box takes minutes to come up in full, and a snapshot build
needs only the registry, which is up within the first few seconds. The
two run side by side; `mode: wait` blocks on the box immediately before
Install, the first phase that needs the whole thing.

**No ECR, no remote builders, no CodeArtifact** on this tier — a hard
rule enforced by the tier itself (`needs.tier.outputs.tier != 'kind'` on
every one of those steps), not left to a lane's `images` flag. A kind
lane's images go to the box's own local registry, `localhost:5001`.

### Why a local registry, and not `ghcr.io`

A kind lane could in principle push its snapshot images to GitHub
Container Registry instead of a registry on the runner itself. It
doesn't, for two reasons:

1. **No lifecycle rules.** GHCR's retention is a manual, per-package
   setting; a CI job that pushes one snapshot per run with no cleanup
   step would accumulate untagged layers forever, on infrastructure this
   repository does not own and cannot budget for.
2. **A fork PR gets a read-only token.** `GITHUB_TOKEN` in a fork's pull
   request has no `packages: write` — pushing anywhere outside the
   runner would fail for exactly the pull requests a public repository
   exists to receive, or need a broader token that reintroduces the
   exposure `public-runners` refuses in the first place.

A registry that lives and dies with the runner sidesteps both: nothing
to expire, and nothing that needs a credential a fork PR does not have.

## The shared tier is unchanged

The shared path in `integration.yaml` is the same code it was before the
tier split — same steps, same conditions, same inputs, not routed
through the `cluster` action's own `mode: shared`. That mode resolves
`kubectl` from bare `PATH` and always logs into ECR once
`ecr-registries` is set; this workflow calls `kubectl` through the
caller's devbox (there is no bare `kubectl` on a self-hosted runner) and
lets an individual lane opt out of ECR, the remote builders and
CodeArtifact with `images: false`. Making the two identical would mean
teaching the action a devbox indirection and a per-lane images flag it
has no way to know about, for a path with nothing wrong with it — so it
was left exactly as it was, and only the kind branches are new.
