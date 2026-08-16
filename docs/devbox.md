# Preparing `devbox.json` for both faces

A repository has two consumers with the same needs and different constraints:
an **employee** on a laptop who wants `just check` to work after `cd`, and
**CI**, which runs `devbox run -- <recipe>` on a runner that has never seen the
repository before.

The goal is one `devbox.json` that serves both, with **nothing shadowed** —
no tool resolving to a different version depending on who is asking.

## The shadowing rule

Every tool has exactly one owner. Pick it deliberately:

| Kind of tool | Owned by | Why |
| --- | --- | --- |
| Go CLIs (`helmctl`, `gemaalctl`, …) | `go.mod` `tool` directive | the version is a dependency like any other, and Renovate updates it |
| Language runtimes, `go`, `node`, `moon` | `.prototools` | proto materialises them per-project, and CI reads the same file |
| System packages, browsers, binaries with payload | `devbox.json` packages | nix is the only thing that can ship them |

**Two owners is the failure.** A Go tool listed in both `go.mod` and
`devbox.json` packages resolves to whichever wins the PATH race — nixpkgs on
one machine, the module pin on another — and nothing reports the difference.
Put Go tools behind a `bin/<tool>` wrapper instead:

```bash
#!/usr/bin/env bash
set -euo pipefail
exec go run github.com/truvity/<repo>/cmd/<tool> "$@"
```

The wrapper carries no version, so it cannot disagree with the pin.

**The inverse case is real too.** A tool that ships more than a binary —
playwright ships browsers — must be nix-owned, and then the npm/Go side has to
*follow* rather than lead. Bumping the npm package to a version nixpkgs has
never packaged breaks at run time, not at install.

## PATH order

```json
{
  "env": {
    "PATH": "$DEVBOX_PROJECT_ROOT/bin:$DEVBOX_PROJECT_ROOT/.proto/shims:$PATH"
  }
}
```

Repo wrappers first, then proto shims, then whatever the machine has. That
ordering is what makes `helmctl` mean the pinned one and not a stray global
install — and it is identical in CI, because CI runs the same `devbox.json`.

## The `init_hook` substitution trap

`init_hook` is **not** a plain shell script. devbox performs its own `${VAR}`
substitution on those lines before any shell sees them, which has three
consequences people discover the hard way:

- **`${VAR:-default}` does not work.** The `:-` is not honoured.
- **An unknown variable becomes empty**, silently. No error, no unbound-variable
  failure — the line just runs with a hole in it.
- **The hook shell has no `PWD`** you can rely on.

So conditional environment logic does not belong there. Put it in `.envrc`,
where it is ordinary shell, and let CI pass overrides through
`devbox run` instead. Keep `init_hook` for unconditional, idempotent
statements: exporting a fixed value, installing hooks, regenerating shims.

## What differs between the two faces, legitimately

Some things *should* differ, and the pattern is to keep a second, static file
rather than branch inside `devbox.json`:

- **AWS config.** The laptop face is generated out-of-band; the CI face is a
  static, repo-owned file with profile names but **no credential source**, so
  the chain falls through to the runner's ambient identity. Workflows select it
  with `AWS_CONFIG_FILE`; pass it to the shared action as `aws-config-file`.
- **Tools that cannot bootstrap on a pristine runner.** The shared action's
  `strip-local-tools` input exists for exactly this, and is deliberately *not*
  the default — a release job needs the clean tree it would dirty.
- **proto itself.** `proto: auto` installs the toolchain when a `.prototools`
  exists. Defaulting it to `true` made every repo without proto fail at
  `exit 127`; "auto" is the honest answer for a shared action.

## Checklist for a new repository

1. Go tools in `go.mod` `tool`, each with a `bin/<tool>` wrapper.
2. Runtimes in `.prototools`.
3. Only nix-shippable things in `devbox.json` packages.
4. `PATH` = `bin` → `.proto/shims` → `$PATH`.
5. Conditional logic in `.envrc`, never `init_hook`.
6. A static CI-face AWS config if any recipe touches AWS.
7. Verify the two faces agree: run a recipe locally and in CI and compare the
   resolved tool versions, not just the exit code.
