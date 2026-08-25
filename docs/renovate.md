# renovate.yaml — the shared self-hosted Renovate

One reusable workflow runs renovate for every repository that carries a
thin caller. The App identity travels by CREDENTIAL NAMES
(`vars.RENOVATE_CLIENT_ID` + `secrets.RENOVATE_APP_PRIVATE_KEY`,
org-level) — the workflow skips cleanly while they are unset, so the
caller file is safe to carry before the entitlement exists.

## The entitlement trap

That clean skip cuts both ways: **a repo outside the org
variable/secret's selected scope never runs renovate and never says
so.** Two repositories carried the caller for weeks with renovate
silently entitled to nothing (2026-08-25). When adding a repo, add it
to BOTH selected scopes — and treat "renovate has never opened a PR
here" as a symptom, not a baseline.

## Execution model: npx, daemonless, Node 24

Renovate runs via `npx renovate@<pinned>`, NOT the
`renovatebot/github-action` — that action runs renovate as a **docker
container**, and the ARC runners are daemonless by doctrine; every
containerized run dies on the missing socket. Direct node execution
behaves identically on hosted runners and is also what makes
postUpgradeTasks usable at all (in container mode they execute inside
renovate's image, which carries none of the runner's toolchain).

The Node floor is **24**: renovate 44 uses `RegExp.escape`, and on
older node it dies with `RegExp.escape is not a function` — while the
workflow still exits green. If renovate "succeeds" without scanning,
check this first.

## Inputs

| Input | Purpose |
|---|---|
| `runner` | Scale-set label. Private repos use the ARC pool (hosted minutes bill); public repos may keep the hosted default (free). Repos whose postUpgradeTasks build heavy toolchains need the LARGE profile. |
| `allowed-commands` | JSON array allowlisting postUpgradeTasks commands (`RENOVATE_ALLOWED_COMMANDS`). Must match the repo's renovate.json commands EXACTLY — this is a security allowlist, renovate refuses anything else. Default `[]`. |
| `log-level` | `debug` to diagnose silent runs. |

## Integrating a repo whose pin bumps require derived files

The gitops pattern (pin bump → rendered values → golden snapshots),
first proven 2026-08-25:

1. Annotate the pin and add a custom regex manager over it.
2. A packageRule with `postUpgradeTasks` running the regeneration
   commands, `executionMode: "branch"`, and fileFilters for everything
   the commands may touch — the update PR then carries its own derived
   files and is born green instead of red on a drift check.
3. Pass the exact same commands via the caller's `allowed-commands`.
4. **Set `platformCommit: "disabled"`** in the repo's renovate.json.
   With an App token renovate defaults to GitHub's GraphQL commit API
   (verified signatures); on large multi-file commits it can fail with
   `Platform-native commit: unknown error` AFTER postUpgradeTasks
   succeed, and the branch is silently dropped as inactive. Plain git
   commits (bot author preserved) are the provably-working path.

## Version pinning

The renovate npm version in this workflow is pinned and annotated —
renovate updates renovate. When bumping majors, re-check the Node floor
in the upstream release notes before merging.
