# Renovate — how the engine is run

How the fleet is scheduled, scoped and given tokens is
[fleet.md](fleet.md#renovate-fleetyaml). This document is the other
half: how Renovate itself is executed, and what a repository has to do
to be updatable by it.

Until v3.0.0 there was also a `renovate.yaml` every repository called
from a workflow of its own, entitled by an organisation variable and
secret with a hand-kept selected-repository list. Its defining failure
is worth remembering, because it is what the fleet shape was built to
make impossible: **a repository outside the selected scope never ran
renovate and never said so.** Two repositories carried the caller for
weeks, entitled to nothing (2026-08-25). The fleet run names every
enrolled repository it cannot reach, in the run summary, individually —
"renovate has never opened a PR here" is a symptom, never a baseline.

## Execution model: npx, daemonless, Node 24

Every repository's job runs Renovate via `npx renovate@<pinned>`, NOT the
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

## How a repository is configured

Each job runs with `onboarding: false` and a required config: a
repository with no renovate config at its root is an error, not a quiet
skip. Estate-wide policy — majors above all — is one file in the caller
repository, loaded as defaults under each repository's own config; see
[fleet.md](fleet.md#deciding-majors-once-in-the-caller-repository).

Three of `renovate-fleet.yaml`'s inputs decide how the engine behaves,
rather than which repositories it sees:

| Input | Purpose |
|---|---|
| `runner` | Scale-set label. The private estate uses the ARC pool (hosted minutes bill); the public estate keeps the hosted default (free). An estate whose postUpgradeTasks build heavy toolchains needs the LARGE profile. |
| `allowed-commands` | JSON array allowlisting postUpgradeTasks commands (`RENOVATE_ALLOWED_COMMANDS`). Must match the repositories' renovate.json commands EXACTLY — this is a security allowlist, renovate refuses anything else. Default `[]`. |
| `log-level` | `debug` to diagnose silent runs. |

## Why the approval is an approval, and not a ruleset bypass

Renovate cannot approve its own pull requests, so on a repository whose
branch protection requires a review an automerge-enabled non-major PR
sits green and unmergeable forever. Five such PRs were stuck across the
estate on 2026-09-06 — every one green, none mergeable.

A standing ruleset bypass would also unblock them, and is the wrong
answer: it is a permanent hole in branch protection that applies to
every PR the App opens, and it leaves no trace on the PR. An approval
from a second App keeps the requirement enforced, is scoped to exactly
the PRs the sweep matches, and appears in the PR's review history like
any other. It is turned off by clearing one input
(`approver-github-app` / `approver-client-id`).

What it will not approve: anything carrying the `major` label, which the
shared preset (`default.json`) stamps on major updates, and anything a
review has already decided. Majors always get a human. Approving early
is safe — GitHub's auto-merge still waits for every required check, so a
red PR stays unmerged with an approval on it.

## Integrating a repo whose pin bumps require derived files

The gitops pattern (pin bump → rendered values → golden snapshots),
first proven 2026-08-25:

1. Annotate the pin and add a custom regex manager over it.
2. A packageRule with `postUpgradeTasks` running the regeneration
   commands, `executionMode: "branch"`, and fileFilters for everything
   the commands may touch — the update PR then carries its own derived
   files and is born green instead of red on a drift check.
3. Pass the exact same commands via the fleet caller's
   `allowed-commands`. It is estate-wide, so a command one repository
   needs is a command every repository in that estate may run — keep the
   list to things that are safe everywhere.
4. **Set `platformCommit: "disabled"`** in the repo's renovate.json.
   With an App token renovate defaults to GitHub's GraphQL commit API
   (verified signatures); on large multi-file commits it can fail with
   `Platform-native commit: unknown error` AFTER postUpgradeTasks
   succeed, and the branch is silently dropped as inactive. Plain git
   commits (bot author preserved) are the provably-working path.

## Version pinning

The renovate npm version in `renovate-fleet.yaml` is pinned and
annotated — renovate updates renovate. When bumping majors, re-check
the Node floor in the upstream release notes before merging.
