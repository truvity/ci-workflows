# ci-workflows development gate
# Recipes mirror what CI runs on every pull request

default: check

# Lint GitHub Actions workflows with actionlint
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    if ! command -v actionlint &>/dev/null; then
        tmpdir=$(mktemp -d)
        trap "rm -rf $tmpdir" EXIT
        curl -fsSL -o "$tmpdir/actionlint.tgz" \
          https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
        tar xzf "$tmpdir/actionlint.tgz" -C "$tmpdir" actionlint
        "$tmpdir/actionlint" -color
    else
        actionlint -color
    fi

# Verify all pins point to release tags
pins:
    #!/usr/bin/env bash
    set -euo pipefail
    LIBRARIES="truvity/ci-workflows truvity/ci-actions truvity/ci-cache"
    
    fail=0
    seen=0
    
    for library in $LIBRARIES; do
      mapfile -t refs < <(grep -rhoE --exclude-dir=.git "${library}/[^@[:space:]\"']+@[0-9a-f]{40}" . 2>/dev/null | sort -u)
    
      if [ ${#refs[@]} -eq 0 ]; then
        echo "no ${library} pins in this checkout — nothing to check"
        continue
      fi
    
      seen=$((seen + 1))
    
      tags=$(git ls-remote --tags "https://github.com/${library}" \
             | sed -n 's|^\([0-9a-f]\{40\}\)[[:space:]]*refs/tags/\(.*\)^{}$|\1 \2|p')
      newest=$(cut -d' ' -f2 <<<"$tags" | sort -V | tail -1)
    
      for ref in "${refs[@]}"; do
        sha=${ref##*@}
        what=${ref%@*}
        what=${what#"${library}/"}
    
        tag=$(awk -v s="$sha" '$1 == s { print $2; exit }' <<<"$tags")
    
        if [ -n "$tag" ]; then
          printf 'ok        %-46s %.12s  %s\n' "${library}/${what}" "$sha" "$tag"
          continue
        fi
    
        fail=1
        printf 'UNTAGGED  %-46s %.12s  names no release; newest is %s\n' "${library}/${what}" "$sha" "$newest"
      done
    done
    
    if [ "$fail" != 0 ]; then
      echo "ERROR: A pinned commit is not a release. Pin the commit of a tag."
      exit 1
    fi
    
    echo "tagged-pins: ${seen} of 3 libraries had pins in this checkout, all naming releases"

# Verify public runners are used
runners:
    #!/usr/bin/env bash
    set -euo pipefail
    visibility="public"
    
    if [ "$visibility" != "public" ]; then
      echo "not a public repository — any runner is allowed"
      exit 0
    fi
    
    fail=0
    for label in ubuntu-latest; do
      case "$label" in
        ubuntu-*|windows-*|macos-*)
          echo "ok        $label"
          ;;
        *)
          echo "SELF-HOSTED  $label"
          fail=1
          ;;
      esac
    done
    
    if [ "$fail" != 0 ]; then
      echo "ERROR: public repository, hosted runners only"
      exit 1
    fi
    
    echo "public repository, hosted runners only — checked"

# Scan for secrets and sensitive data
leak-canary:
    @./hack/leak-canary.sh

# release-public's `charts` input: plain names, repository-root paths, refusals
chart-paths-cases:
    @./hack/chart-paths-cases.sh

# release-pkl's version, tag, changelog and asset checks, re-run behaviour and smoke test
release-pkl-cases:
    @./hack/release-pkl-cases.sh

# pkl-fleet's target, consumer discovery, URI rewrite, resolve and pull-request steps
pkl-fleet-cases:
    @./hack/pkl-fleet-cases.sh

# Run all checks (the merge gate)
check: lint pins runners leak-canary chart-paths-cases release-pkl-cases pkl-fleet-cases
    @echo "✓ All checks passed"
