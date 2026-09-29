# The component contract has moved

The contract every public component repository is held to now lives in
one place, truvity/policy:

**<https://github.com/truvity/policy/blob/master/docs/contracts/component.md>**

This page stays so that links to it keep resolving. It no longer carries
rules of its own. Where this repository's other documents touch the
contract, they link there rather than restating it.

## What changed when it moved

Three documents used to describe what a component repository looks like:
this page, truvity/policy's contracts, and ci-plane's normalisation
notes. They are folded into the one above, and its checkable rules carry
IDs, C1 to C13. Differences from what this page said:

- **Charts commit `0.0.0`** as both `version` and `appVersion` (C1); the
  release workflow stamps the tag's version. `0.0.0-dev` is retired.
- **CHANGELOG headings are `## vX.Y.Z`, one per tag**, newest first, with
  at most one optional `## Unreleased` on top, and a heading for the
  latest tag (C5). This page asked for headings on human-cut versions
  only.
- **The README gains `Consumers` and `Neighbours`** (C8). `Consumers`
  names who uses the repository and through which surface, replacing
  this page's rule that a component never names its consumers.
- **The rules are checked mechanically.** truvity/ci-actions'
  `policy-conformance` action evaluates C1 to C12; `check.yaml` runs it
  when a caller sets `policy-conformance: true`
  ([README](../README.md#install-and-a-worked-example)).

The canonical copies of the shared scripts stay here:
[`hack/leak-canary.sh`](../hack/leak-canary.sh) and
[`hack/golden.sh`](../hack/golden.sh), described in
[golden-renders.md](golden-renders.md).
