# A repository in the truvity estate — birth to autopilot

The end-to-end path every estate repository follows, with each step
linking the system that owns it. When all steps are done, the repo
maintains itself: dependencies update, releases cut, and deployments
promote with zero human steps.

The three systems, and where their docs live:

| System | Owns | Docs |
| --- | --- | --- |
| [github-structure](https://github.com/truvity/github-structure) | What the repo IS: settings, protection, rulesets, teams, Apps | `docs/{registry,safety,adoption,doctrine}.md` |
| ci-workflows (this repo) | What the repo DOES on push/PR/schedule: check, release, renovate, devbox-update, auto-release | `docs/` here |
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
- `devbox-update.yaml` → the weekly toolchain alignment
  (`docs/devbox-update.md`)
- `renovate.yaml` → the shared npx-based renovate
  (`docs/renovate.md` — incl. the entitlement silent-skip trap)

## 3. Release — one tag, every artifact

`release.yaml` → `release-public.yaml`: goreleaser builds binaries and
ko images (nested `ghcr.io/truvity/<repo>/<role>` — set `ko-docker-repo`
explicitly; ko's `repositories:` key is inert), charts are packaged and
pushed **deterministically via helmctl** to `ghcr.io/truvity/charts/*`
(identical content ⇒ identical digest). The git tag is the sole version
authority; committed chart versions stay `0.0.0-dev`.

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
2. `CI_AUTOMATION_APP_ID` (variable) and `CI_AUTOMATION_PRIVATE_KEY`
   (secret) are entitled to the repo
3. `vars.AUTO_RELEASE == "true"` — the deliberate arming act

Stagger the caller's cron: repos tagging in the same minute produce
gitops pin PRs that race each other's rebases.

After step 5 the loop is closed: a dependency bump lands, merges
itself, releases itself, and deploys itself — and every link in that
chain is a reviewable record (renovate PR, tag, release, pin PR).
