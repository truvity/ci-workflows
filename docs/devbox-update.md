# devbox-update — version parity, and the toolchain triple's one owner

The `devbox-parity` action, run once per repository by
[`parity-fleet.yaml`](fleet.md#parity-fleetyaml), refreshes a
repository's devbox packages and, for Go repositories, keeps **three
things that must agree** aligned in the same pull request:

1. the `go` binary devbox ships (nixpkgs),
2. the Go that `golangci-lint` was **built with** (also nixpkgs),
3. the `go` directive in `go.mod`.

This document is the why, the rules, and every pitfall the rollout hit
(2026-08-23). Read it before touching the action or a fleet caller. The
rules outlived the shape they were found in: until v3.0.0 the same logic
ran from a `devbox-update.yaml` workflow inside each repository, and
every pitfall below was paid for there. The name survives that workflow
because it is still what the run does and what the pull request it opens
is called (`chore/devbox-update`).

## Why three things, and why one owner

- `golangci-lint` refuses to lint a module whose **language** version
  (the `go` directive's minor) is newer than the Go it was compiled
  with: `the Go language version (go1.26) used to build golangci-lint is
  lower than the targeted Go version (1.27.0)`. The cap is the **minor**
  line; patch differences are fine (a 1.26.5-built linter lints a
  `go 1.26.7` module).
- The directive is also the minimum **toolchain**: with `GOTOOLCHAIN=auto`
  (the default), `go` downloads whatever `go.mod` names, so the
  directive may run **ahead of the nixpkgs binary** — that is how stdlib
  CVE fixes reach CI before nixpkgs catches up.
- Therefore the directive has one cap (golangci's build minor) and one
  wish (the newest patch of that line). Two writers — renovate bumping
  the directive, the devbox refresh moving the binaries — produced the
  2026-08-22 estate-wide lint panics and a day of gate rules papering
  over the split. **One owner: the parity job.** Renovate's gomod manager
  leaves `go` alone (`matchDepNames: ["go"], enabled: false` in every Go
  repository's renovate.json, with a description naming the parity job).

The rule, in one line:

> language minor ≤ golangci-lint's build minor; patch = the newest
> release of that line; never downward.

When nixpkgs moves `go` and `golangci-lint` together, the next full run
carries the whole minor migration as one ordinary PR per repository.

## Two cadences, one owner

The estate's parity caller runs a **daily** cron. `mode: auto` (the
default):

| Day | What runs | What can change |
|---|---|---|
| `full-update-day` (Monday, `1`) | `devbox update` + align | devbox.lock, devbox.json, go.mod |
| every other day | align only | go.mod — and only if Go shipped a patch |

So a stdlib CVE reaches CI within a day (the cadence renovate's hourly
bumps used to give — bar#641's review caught the regression when
v2.10.0 first moved the directive onto a weekly cadence), and six days a
week produce no lock churn.

`mode: full` and `mode: align` force a path for the whole run. A human
dispatching right after a Go release wants `align` today, not next
Monday:

```
gh workflow run "parity (<estate> estate)" --repo <caller repository> -f mode=align
```

(only if the caller exposes `mode` as a dispatch input; otherwise a
plain dispatch runs the caller's `mode`, `auto` by default, which on a
non-Monday is align-only.) A single repository that needs another mode
than the run's declares it in its own `.devbox-parity.json` — see
[fleet.md](fleet.md#devbox-parityjson).

## The align step, exactly

```
lang    = go.mod's `go` directive        — READ ONLY, never changed here
tc      = go.mod's `toolchain` directive, or lang if absent
built   = "built with goX.Y.Z" from `golangci-lint version`
          (fallback: devbox's `go env GOVERSION` if there is no linter)
cap     = X.Y of built
if lang's minor > cap:  warn, touch nothing (a human made that mismatch)
target  = newest goX.Y.* on https://go.dev/dl/?mode=json
          (fallback: none → leave go.mod alone this run)
if target > tc:  go mod edit -toolchain=go<target>
                 (or -toolchain=none when target == lang: one line says it)
```

Repositories listing further modules in `.devbox-parity.json`
(`module-dirs`) get the same step per module; the root module is always
considered.

**The language directive is never raised by automation.** v2.10.0–3
collapsed both into one `go` line and thereby raised phoenix from
language 1.23 to 1.26 — which activated go vet's printf analyzer and
broke master. The language version is a code-semantics decision for
the repository's team; the toolchain is the CVE channel and is
automation's to move.

## Running it

A repository runs nothing and holds no key. It is listed under
`parity.<estate>` in the caller repository's enrolment file and carries
a `devbox.json`; one scheduled job per estate does the rest. The caller
shape, the inputs and the enrolment rules are in
[fleet.md](fleet.md#parity-fleetyaml).

The PR is opened by the App the caller repository mints or exchanges a
token for, and **auto-merges when the repository's required checks
pass** — the repository's own CI is what validates the aligned triple.
**Where the default branch has no required checks, auto-merge is NOT
armed** and a human merges: `gh pr merge --auto` merges *immediately*
when nothing gates it, which is how phoenix#29 landed a red lint/test
on 2026-08-23 (the migrated profile carries no required checks by a
deliberate decision).

## Pitfalls — every one of these was hit live

1. **`secrets: inherit` does not cross an organization boundary.**
   Callers in the second organisation reached the workflow with every
   secret empty and `vars` resolving fine, which reads as a malformed
   workflow rather than as a missing secret. Found 2026-08-19 and paid
   for twice; it is why the fleet workflows declare every secret and
   pass them explicitly, never by inheritance.
2. **A reusable workflow's `permissions:` block is a ceiling.** Not a
   problem here (contents: read is all parity-fleet.yaml needs from
   GITHUB_TOKEN; the App token does the writes), but it is why
   check.yaml carries no block at all — see its header.
3. **Never `devbox run -- jq '<program>'`.** devbox re-quotes argv and
   mangles the program (`syntax error, unexpected ')'`). jq is the
   runner's. The same trap applies to any tool given a program as a
   string.
4. **A repository's devbox `init_hook` may print to stdout.** gitops's
   prints the lefthook sync line on every `devbox run`, which corrupted
   `go mod edit -json` output. The current directive is read from
   go.mod with awk — nothing in the read path goes through devbox.
5. **The directive is monotonic.** The first prototype run hit a
   fallback and *downgraded* 1.26.6 → 1.26.5; the repository's pre-push
   govulncheck refused the push. `sort -V` picks the higher of current
   and target; a go.dev outage leaves go.mod untouched.
6. **The push must run inside devbox.** Repositories' lefthook pre-push
   hooks call their tools bare (`just …`), relying on the devbox shell
   every human has. The runner's plain shell has no such PATH and the
   push died with `just: command not found`. The hooks are the safety
   net that vets the aligned directive — they must be able to run, so
   the push is `devbox run -- git push`.
7. **The `dependencies` label is self-created** (`gh label create
   --force`, idempotent). The old "must already exist" prerequisite
   failed *after* the branch was pushed — the worst moment.
8. **go.mod counts as movement.** The "did anything change" gate covers
   devbox.json, devbox.lock and go.mod; before v2.10.0 a go.mod-only
   change was invisible and produced no PR.
9. **`gh run rerun` re-evaluates the original head SHA** — useless for
   testing a fix. Dispatch a fresh run instead.
10. **Never raise the language directive by automation.** Raising
    `go 1.23` to `1.26` activated go vet's printf analyzer on phoenix
    and broke master — a semantic change that belongs to the team.
    Automation moves the `toolchain` line only.
11. **`gh pr merge --auto` on a repo with no required checks merges
    immediately.** Gate the arming on a required check actually
    existing; otherwise leave the PR for a human.

    Read **both** places a required check can live, because either one
    is a green worth waiting for:

    - a **repository ruleset**, through
      `GET /repos/{owner}/{repo}/rules/branches/{branch}` — the
      effective rules for that branch, already merged across every
      ruleset that applies. It needs only `Metadata: read`.
    - **classic branch protection**, through
      `GET /repos/{owner}/{repo}/branches/{branch}/protection`, falling
      back to GraphQL `refUpdateRule` when that is not readable: REST
      needs `Administration: read`, which neither the App token nor
      GITHUB_TOKEN carries, so it 404'd on every private repo and the
      gate silently concluded "no required checks". `refUpdateRule`
      shows the rule to any viewer (`null` = no protection, `[]` = no
      required contexts) — but **as it applies to that viewer**: where
      `enforce_admins` is false, an administrator sees `[]` on a branch
      that really does require checks, which is why REST goes first
      wherever it answers.

    Reading only classic protection left every ruleset-gated repository
    unarmed. A permission gap in the *probe* fails toward manual
    merging, which looks like policy, not like a bug — which is exactly
    why it went unnoticed for so long.
12. **The ARC runner image has no `gh`.** Hosted runners preinstall the
    GitHub CLI; the pool image bakes nix, devbox and build tools only.
    parity-fleet.yaml installs a pinned `gh` when absent (gate on detection,
    the setup-devbox doctrine). The private estate's parity caller SHOULD
    run on the pool (`runner: ${{ vars.CI_RUNNER_LABEL_LARGE }}`):
    the pre-push hook compiles the module, and that took 15–22 minutes
    on a 2-core hosted runner with no caches (paid minutes, a 30-minute
    ceiling, and it reads as a hang) against ~5 minutes on the pool.
    And the pool is **arm64** where hosted runners are amd64 — the first
    pinned install hardcoded `linux_amd64` and died on the pool with
    `cannot execute binary file: Exec format error`. Detect with
    `uname -m`; never bake an architecture into a tarball name.
13. **One fixed branch, force-pushed.** Date-named branches collide on a
    same-day re-run; `chore/devbox-update` is force-pushed and an open
    PR for it is updated in place rather than duplicated — renovate's
    shape.
14. **Prototype on a fork first.** Forks carry no App secrets, so the
    fork variant used GITHUB_TOKEN with `contents: write` +
    `pull-requests: write`, Actions enabled on the fork, the "allow
    Actions to create PRs" toggle on, and the label pre-created. Every
    failure that remains after that is real. The 2026-08-23 rollout
    found pitfalls 3, 5, 7 and 8 on the fork and 1, 4 and 6 on the
    first estate run — a fork catches the logic, production catches
    the environment.

## What this does NOT do

- It does not find modules by itself. The align step reads `./go.mod`
  and the directories a repository names in `module-dirs`, nothing else.
  Before that key existed it read the root only, and a multi-module
  repository with no root module got a clean run saying `no go.mod —
  nothing to align` while its toolchain lines moved by hand (2026-08-23:
  one such repository carried two live stdlib CVEs that way). A
  repository that keeps its modules in subdirectories must say so.
- It does not choose the minor line. nixpkgs does, by shipping `go` and
  `golangci-lint` built against it; the next full run follows.
  Renovate's `constraintsFiltering: strict` (kept in every config) stops
  it picking *dependency* versions that require a newer Go than the
  directive in the meantime.
- It does not skip a repository's hooks or checks — ever. A red PR is
  the repository telling you the aligned triple broke something; that
  is the signal, not an obstacle.
