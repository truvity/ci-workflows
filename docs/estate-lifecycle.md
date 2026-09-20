# A repository in the truvity estate — birth to autopilot

The end-to-end path every estate repository follows, with each step
linking the system that owns it. When all steps are done, the repo
maintains itself: dependencies update, releases cut, and deployments
promote with zero human steps.

The three systems, and where their docs live:

| System | Owns | Docs |
| --- | --- | --- |
| [github-structure](https://github.com/truvity/github-structure) | What the repo IS: settings, protection, rulesets, teams, Apps | `docs/{registry,safety,adoption,doctrine}.md` |
| ci-workflows (this repo) | What the repo DOES on push/PR/schedule: check, release, auto-release — and, for the whole estate at once, renovate and version parity | `docs/` here |
| [ci-plane](https://github.com/truvity/ci-plane) | Where CI RUNS: ARC runners, caches — and the estate's artifact doctrine | `docs/{architecture,day-1-install,day-2-operations,normalization}.md` |

## 1. Birth — declare the repo

Add a row to the registry (in our estate: `cfg/github.yaml` in gitops)
and deploy. Profile decides everything defaultable; a public repo that
releases artifacts also declares its tag ruleset:

```yaml
my-repo:
  profile: public
  description: >-
    One sentence, shown on GitHub.
  tag_rulesets:
    - name: release-tags
      pattern: refs/tags/v*
      bypass_teams: [role-runner-release]
      bypass_apps: [4597170]   # ci-automation — the auto-release bot
```

The engine creates the repo, protection, and rulesets; preflight and
drift keep them honest. Naming and artifact rules: ci-plane's
`docs/normalization.md` (R/N/B/P criteria).

## 2. CI — adopt the shared workflows

Thin callers, pinned by SHA with the version in a comment (renovate
keeps the pin current — a drifting pin is a defect, doctrine B6):

- `ci.yaml` → `check.yaml` — the one required context, running your
  Justfile recipes on the ARC pool
- `security.yaml` → `check.yaml` (daily schedule, non-blocking scans)

That is the whole list. **Dependency updates and version parity are not
callers at all**: they run as one job per estate from one caller
repository (`docs/fleet.md`), and a repository opts in by being enrolled
there and carrying a `renovate.json` and a `devbox.json`, plus the
required `check`. What that job does to a Go repository's toolchain
triple is `docs/devbox-update.md`; how the renovate engine itself is
run is `docs/renovate.md`. Until v3.0.0 this library also shipped
`renovate.yaml`, `devbox-update.yaml` and `auto-approve.yaml` for the
per-repository shape; they are gone.

`node-cache` defaults to `true` in `check.yaml` and `integration.yaml`
(no need to pass it): on a self-hosted (ARC) runner the job probes the
CI plane's npm read-through cache
(`npm-cache.ci-cache.svc`, INF-581/583) and points npm/yarn at it when
it answers — a down cache degrades the job to *slow* (direct npmjs
with a warning), never to *broken*. GitHub-hosted runners skip the probe,
and `integration.yaml` caches `.yarn/cache` only when a root `yarn.lock`
exists, so the default is a no-op for non-Node repositories. Pass
`node-cache: false` to opt out.

`goproxy` falls back to the caller's `vars.CI_GOPROXY` when the input is
empty — a reusable workflow reads the calling repository's configuration
variables — so callers no longer need to pass it (it takes effect with
`go-cache-bucket`, as before). Do not pin `GOPROXY`
in a repository's `devbox.json` `env` block: `devbox run` re-applies
that block over the job environment and the CI proxy is silently
bypassed. `setup-devbox` warns when it finds one.

## 3. Release — one tag, every artifact

`release.yaml` → `release-public.yaml`: goreleaser builds binaries and
ko images (nested `ghcr.io/truvity/<repo>/<role>` — set `ko-docker-repo`
explicitly; ko's `repositories:` key is inert), charts are packaged and
pushed **deterministically via helmctl** to `ghcr.io/truvity/charts/*`
(identical content ⇒ identical digest). The git tag is the sole version
authority; committed chart versions stay `0.0.0-dev`.

A CLI other repositories install through devbox names its goreleaser
archive id in `nix-flakes`. The release then carries
`<id>_<version>_nix-flake.tar.gz`, a flake that fetches that release's
archives by sha256 (linux amd64/arm64, darwin arm64). A consumer adds the
asset URL with `#<id>` to its devbox.json, and devbox.lock pins it:

```json
"https://github.com/truvity/access-roster/releases/download/v1.7.0/accessctl_1.7.0_nix-flake.tar.gz#accessctl": ""
```

## 4. Promotion — pull, never push

The repo never opens deployment PRs. Consumers (gitops) carry a
renovate-annotated pin per artifact; renovate sees the new release,
opens the pin PR, automerges it behind render+golden gates, and ArgoCD
rolls. The pin PR is the deploy record.

## 5. Autopilot — arm auto-release

`auto-release.yaml` → the shared auto-release: weekly, the
ci-automation App cuts the next patch tag when renovate's automerged
bumps have moved master past the latest release. Prerequisites, all
declared, none hand-set:

1. the tag ruleset carries the App in `bypass_apps` (step 1)
2. the repo can get a token of that App — see below
3. `vars.AUTO_RELEASE == "true"` — the deliberate arming act

Stagger the caller's cron: repos tagging in the same minute produce
gitops pin PRs that race each other's rebases.

### Where the tagging token comes from

`token-source`, the same input the [fleet workflows](fleet.md#where-the-tokens-come-from)
take:

| `token-source` | the caller passes | the job |
|---|---|---|
| `app-key` (default) | `app-id`, and the App's private key as the `CI_AUTOMATION_PRIVATE_KEY` secret | mints with `actions/create-github-app-token` |
| `access-roster` | `access-roster-issuer` and `github-app` (the App's catalogue id); no secret | exchanges its own GitHub OIDC token at the issuer for an installation token, via the [access-roster action](https://github.com/truvity/access-roster) |

```yaml
# .github/workflows/auto-release.yaml — no key anywhere
permissions:
  contents: read
  id-token: write          # the exchange needs it
jobs:
  tag:
    if: vars.AUTO_RELEASE == 'true'
    uses: truvity/ci-workflows/.github/workflows/auto-release.yaml@<sha> # vX.Y.Z
    with:
      token-source: access-roster
      access-roster-issuer: https://access.example
      github-app: ci-automation
```

With `access-roster` there is no key in the repository, in an
organisation secret, or in an entitlement list: the issuer holds the App
and its grants decide which **job** may have a token of it. The token
this job asks for is **one repository — its own — with `contents: write`
and `pull_requests: read`**: enough to push the tag and to read the
merged PR's labels for the security lane, and nothing else. The grant
pins the job's identity: the repository, `refs/heads/master`, the event,
this repository's `auto-release.yaml` as `job_workflow_ref` at any
commit, and the caller's own file as `workflow_ref`.

Two things change with the source and are easy to miss:

- **`id-token: write` in the caller.** A called workflow can only narrow
  what its caller grants. The `app-key` job does not ask for it, so
  callers that stay on keys need no edit — but a caller switching source
  and forgetting the permission fails at job start.
- **A different App, so a different `bypass_apps` id.** The issuer's App
  is not the one whose key lives in 1Password; the v* tag ruleset must
  carry the new App's id (step 1) before the first tag push, or the push
  is rejected.

After step 5 the loop is closed: a dependency bump lands, merges
itself, releases itself, and deploys itself — and every link in that
chain is a reviewable record (renovate PR, tag, release, pin PR).
