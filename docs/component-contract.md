# The component contract — what a public component repository looks like

A **component repository** is a public repository that ships mechanism
for an estate to consume: Helm charts, a Go module, binaries, or any mix
of them, released together. The platform's edge, identity, secret plane
and networking each live in one. They grew one pull request at a time,
so this page writes down once what every one of them looks like, and
each repository is audited against it.

The rules come in three kinds. **Shape** is what a stranger meets: the
README, `docs/`, the CHANGELOG. **Proof** is what CI holds the repository
to: a strict schema, golden renders, negative fixtures, the leak canary.
**Release** is how a version reaches a consumer: one tag, a stated
cadence, and an adoption gate on the consumer's side.

[github-structure](https://github.com/truvity/github-structure) is the
reference shape for the documentation; this page generalises it.
[estate-lifecycle.md](estate-lifecycle.md) is the path every repository
follows from birth to autopilot; this page is what a *component* adds to
it.

## 1. The rules that make a repository public

These are not negotiable per repository, because public history cannot be
unpublished:

1. **MIT**, with the licence file at the root.
2. **Mechanism only.** Nothing names an account, a zone, a hostname, a
   cluster, an issuer, a bucket, a key or a secret path. Every such thing
   is an input with a neutral default, and the consuming estate supplies
   it from its own private repository. §7 has the rule in full.
3. **Secrets are the caller's.** A chart takes the *name* of a Secret, a
   module returns a secret as an output; neither stores one, generates one
   into a manifest, or knows a secret manager.
4. **Hosted runners only.** §8.
5. **One tag stamps everything.** §4.

## 2. README

The README is for someone deciding whether this is theirs to use, and
then installing it. It is not the reference: tables of every value live in
`docs/reference.md`. In this order:

| Section | What it answers |
|---|---|
| title and one sentence | what it is |
| the artifacts table | what ships, where it is published (`oci://…`, the Go module path), and whether each is shipped or planned |
| who it is for | the platform it assumes: which controller, which issuer, which cloud — and what it deliberately does not install |
| the model | one paragraph, a diagram if it earns one: the two or three nouns a reader needs and how they relate |
| install and a worked example | the `helm install` / `go get` line and a values file or Go snippet with **neutral values** (`example.com`, `*.example`, `eu-example-1`, `example-*`) that renders or compiles as written |
| documentation | links to the four `docs/` entry points (§3) |
| the rule that makes this repository public | mechanism only, and that `hack/leak-canary.sh` enforces it |
| status | "used in production by its maintainers", and nothing about who or at which version (§9) |
| development | `devbox shell`, `just check`, how to regenerate goldens |
| releasing | this repository's release mode (§4) in one or two sentences |
| licence | MIT, a link to `LICENSE` |

A chart's own `README.md` under `charts/<chart>/` is optional; when it
exists it points to `docs/reference.md` rather than repeating it.

## 3. `docs/`

Four entry points, always at these paths, because a reader who has read
one component knows where to look in the next:

| File | Holds | Test for whether something belongs |
|---|---|---|
| `docs/adoption.md` | how a platform takes this into use: prerequisites, install order, adopting objects that already exist, **the zero-diff gate**, and every breaking upgrade with its steps | "I am about to change what runs" |
| `docs/safety.md` | what can break and how the component prevents it: each render-time refusal, each default chosen because the other one failed, each trap, with the failure that earned it | "what goes wrong if I do the obvious thing" |
| `docs/reference.md` | every value, flag, input and output: default, type, what it does, when it is required | "what does this knob do" |
| `docs/doctrine.md` | the design rules: what this repository owns and what the consuming estate owns, and the reasons for the shape | "why is it like this, and would a change fit" |

The zero-diff gate, stated once here and repeated in every
`adoption.md`: **a consumer adopts a release only when the render (or the
preview) it produces is byte-identical to what runs, or differs exactly
by the change the release announces.** Moving from hand-written objects
to a chart is one pull request whose render diff is empty; tightening a
default is a separate release, adopted separately.

Incidents are kept in `safety.md` because a rule without its incident
reads as pedantry, but they are told without the estate's particulars:
"a consuming estate", never its name, its clusters or its tickets.

A repository with a larger documentation tree (a service with a console,
an operator guide, per-integration pages) keeps it, and the four files are
then short index pages into that tree. The paths are the contract, not
the length.

## 4. Release and versioning

**One tag stamps every artifact.** Pushing `vX.Y.Z` releases every chart
at `X.Y.Z`, the Go module at `vX.Y.Z`, and any binaries and images at
`X.Y.Z`. A chart's committed `version` and `appVersion` are the
placeholder `0.0.0` and never move; the release workflow stamps them.
Consequently a consumer pins one version per repository, and two charts
from one repository at different versions are a lag to close, not a
choice.

**Semantic versioning, read from the consumer's side.** A **major** is
anything that makes an existing values file, an existing live object or
an existing import stop working: a removed or renamed value, a changed
selector (immutable on a live Deployment, so an upgrade becomes a delete
and recreate), a new required value without a default, a changed object
name. A **minor** adds a capability whose default renders what the
previous version rendered. A **patch** changes no render and no API: a
fix to a refusal, a dependency, a document. A Go module at v2 or later
carries `/vN` in its module path **before** the tag is pushed; a tag
whose `go.mod` disagrees can never be fetched as a module, and a tag,
once fetched by a proxy, cannot be taken back.

**Who cuts the tag.** Every component carries the shared auto-release
caller (estate-lifecycle.md, step 5). It is disarmed until
`vars.AUTO_RELEASE` is `"true"`, and when armed it **only ever cuts
patches**:

- on a push to the default branch whose merged pull request carries the
  `security` label (renovate's vulnerability alerts), immediately;
- once a week, when renovate's automerged bumps have moved the default
  branch past the latest tag.

It never cuts a minor or a major, and it never cuts the first release of
a repository. **Minors, majors and every first release are manual
tags**, pushed by a person after the CHANGELOG heading for that version
has merged. The reason for the split: a patch has, by the definition
above, nothing for a consumer to decide, so it may flow on its own and a
security fix should not wait for a person; a minor or major carries a
decision, and its tag is the moment someone made it.

The trap in that split: the weekly lane asks only whether the default
branch has moved past the latest tag, not what moved it. A feature merged
and left untagged in an armed repository ships in the next weekly
**patch**. So the minor is tagged when the feature merges, not when it is
convenient.

Each README's **Releasing** section says which of these applies today:
auto-release armed or not, and that minors and majors are manual.

## 5. CHANGELOG

**One convention: `CHANGELOG.md` at the root, a `## vX.Y.Z` heading per
version, newest first, prose bullets written for the consumer.**

```markdown
## v2.0.0

- **Breaking: the pod selector gains `app.kubernetes.io/instance`.** A
  selector is immutable, so an existing install is deleted and recreated
  rather than upgraded; see docs/adoption.md.
- **`podLabels` adds labels to the pod.** Unset renders what 1.2.0
  rendered.
```

Why this and not the commit subjects the GitHub Release already lists:
commit subjects are written for the reviewer of a diff, and a consumer
reading a pin-bump pull request needs a different sentence — what changes
in the render, what must be done first, and whether a default moved. The
file travels with the source (module proxies, tarballs, forks) where a
GitHub Release does not, and it is reviewed in the same pull request as
the change it describes.

The rules:

- The pull request that makes a consumer-visible change adds its bullet
  under the heading of the version it will be tagged as, creating the
  heading if it is the first.
- A breaking bullet starts with **Breaking:** and names the adoption
  step.
- A patch that auto-release cuts for dependency bumps alone has no
  heading: nothing changed for the consumer, and its GitHub Release lists
  the bumps. A version missing from the CHANGELOG therefore means exactly
  that.
- The GitHub Release keeps goreleaser's generated notes (commit subjects,
  grouped); the two are complementary, not alternatives.

## 6. Charts: schema, goldens, negative fixtures

Every chart has:

1. **`values.schema.json`**, strict: `additionalProperties: false` at the
   top level and inside every object the chart itself defines;
   Kubernetes passthrough fields (resources, affinity, tolerations,
   selectors) stay open. A typo must fail the render instead of being
   silently ignored.
2. **Golden renders** — `tests/cases/<chart>/<case>/values.yaml` rendered
   and compared byte-for-byte with `tests/golden/<chart>/<case>.yaml` by
   the vendored `hack/golden.sh` ([golden-renders.md](golden-renders.md)).
   At least a `minimal` case and a case that sets every value.
3. **Negative fixtures** — `tests/invalid/<chart>/<rule>.yaml`, one per
   refusal (a schema rule or a render-time `fail`), each otherwise valid
   so it fails for its one reason, plus `unknown-key.yaml`. The `lint`
   recipe renders every one and fails if any of them renders. A rule
   without a fixture is a rule that will quietly stop working.

## 7. The leak canary, and "no organisation specifics"

`hack/leak-canary.sh` runs in CI as its own recipe. The canonical copy is
this repository's [`hack/leak-canary.sh`](../hack/leak-canary.sh);
components vendor it and may **narrow or drop** a pattern only with a
comment in the script's header saying why the matched text is mechanism.
Never an exception without a reason; never a reason without a pattern
that still catches the real leak.

The traps each copy has met:

- **Hex that looks like an account id.** A 12-digit run inside a commit
  SHA (a nixpkgs pin, a Go pseudo-version's hash) matched an unanchored
  account-id pattern. The pattern is anchored on word boundaries, and
  `go.sum`/`go.mod` are excluded outright: their content is public
  dependency data by definition, and pseudo-version timestamps are long
  digit runs.
- **Generated files.** A recursive walk descended into gitignored state
  (`.devbox/`) whose hashes matched. Scan tracked files only
  (`git ls-files`), as the canonical copy does.
- **The secret-path pattern.** The canonical pattern (a path segment
  named `secrets`) exists for SSM parameter paths. A chart that mounts a
  Secret at a `secrets` directory of its own trips it with mechanism; the
  component copies narrow it to a `secrets` segment followed by two more
  segments. A Kubernetes projected-token path under
  `/var/run/…` is mechanism too, and a repository that uses one must
  say so in the header rather than weaken the pattern for everyone.
- **Mechanism that is the matched text.** A DNS rewrite to the in-cluster
  suffix (`svc.cluster` then `local`) or a module that composes ARNs
  from caller inputs contains the pattern by design; that repository
  drops the pattern and relies on the account-id pattern to catch a
  concrete leak.
- **Documentation placeholders.** Use the cloud's own documented
  placeholder values and `example` domains, never a real value "because it
  is only an example".

- **Commit messages.** The canary reads tracked files, not history. A
  commit that fixed one of these patterns quoted a real account id in its
  message as the example of what must still match — and landed, message
  and all, in every repository that vendors the script. A message is as
  public as a file and cannot be edited after the push. Quote a
  placeholder, never the value.

The canary is a floor. It cannot read prose, so the rest is a review rule
for every file, commit message and pull request text in a public
repository: **no names of the consuming estate's organisations, clusters,
environments, teams, people, internal repositories, tickets or
incidents.** Say "a consuming estate", "an environment", "the source
estate". A label or annotation key under the owner's own domain is an
API, not a leak, but it is an API a stranger inherits, so prefer the
component's own name.

## 8. Hosted runners only

Every workflow in a public repository runs on GitHub-hosted runners:
`runs-on: ubuntu-latest`, and the shared `check.yaml` with its default
`runner`. A public repository's pull requests come from forks, and a
fork's code must never execute on the estate's own infrastructure. Hosted
minutes are free for public repositories, so recipes fan out as wide as
they like. Nothing in a component's CI needs an id-token except the
auto-release tagger.

## 9. Consumers

**The public repository does not name its consumers or the versions they
run.** Its README says "used in production by its maintainers", and
stops. The record of *which consumer pins which version* lives with the
consumer: its pin file is the record, its pin-bump pull request keeps it
current, and that pull request carries the zero-diff (or
exactly-the-announced-diff) render as its evidence.

Why not a "consumed by" line in the component: naming an internal
repository or its environments is an organisation specific; a version
line written by the consumer would need a second pull request in a
repository the consumer does not own for every bump, and would be stale
by construction between the two merges; and the consumer's pin is
already authoritative. A consuming estate that wants the map in one place
keeps a table next to its pins — component, artifact, pinned version,
last audited against this contract.

## 10. The checklist

The audit of a component is one row per repository against these
columns:

| Item | Passes when |
|---|---|
| README | the sections of §2, in order, with a neutral worked example |
| `docs/` | `adoption.md`, `safety.md`, `reference.md`, `doctrine.md` exist and hold what §3 says |
| release | one tag stamps every artifact; chart versions are `0.0.0`; the README states the release mode |
| CHANGELOG | `CHANGELOG.md` with `## vX.Y.Z` headings for every human-cut version |
| charts | strict `values.schema.json`, goldens, `tests/invalid/<chart>/` with `unknown-key.yaml` and one fixture per refusal |
| leak canary | vendored, run in CI, deltas explained in its header, tracked files only |
| organisation specifics | none in code, docs, CHANGELOG, tests, commits or pull request text |
| runners | hosted only |
| consumers | no consumer named; the version map lives with the consumer |
