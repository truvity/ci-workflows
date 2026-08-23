# Golden chart renders — the pattern, and the canonical script

Every public chart repository in the estate pins its rendered output:
`tests/cases/<chart>/<case>/values.yaml` is rendered with
`helm template` and compared **byte-for-byte** against
`tests/golden/<chart>/<case>.yaml`. A template change therefore shows up
as a reviewable diff in the PR — no cluster involved, no "looks fine"
reviews of Go-templated YAML.

Two rules that make it work:

1. **Byte-for-byte, not semantic.** The rendered string is what the
   cluster (and Argo CD's repo-server) sees; a semantic comparison hides
   exactly the whitespace/ordering surprises helm upgrades introduce.
2. **The cases double as schema fixtures.** With `values.schema.json`
   in the chart, every case is validated on render — and each repo's
   lint recipe adds the negative probe (`--set bogusKey=1` must FAIL),
   so the strictness itself is tested.

`hack/golden.sh` in this repository is the CANONICAL copy; chart repos
vendor it verbatim (it is ~50 lines and must run locally without any
fetch — local `just test` and CI run the identical file). When it
changes here, Renovate will not propagate it: update vendored copies
deliberately, the way the leak canary is maintained.

Usage in a chart repo:

    hack/golden.sh          # compare (the `test` recipe)
    hack/golden.sh update   # regenerate; review the diff before commit
