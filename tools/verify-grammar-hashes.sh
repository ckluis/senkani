#!/usr/bin/env bash
#
# verify-grammar-hashes.sh — Supply-chain integrity check for vendored
# tree-sitter grammars.
#
# For each grammar declared in `Sources/Indexer/GrammarManifest.swift`,
# recompute SHA-256(parser.c [+ scanner.c when present]) and compare
# against the declared `contentHash`. Exits non-zero on any mismatch
# or missing grammar.
#
# Wired into `tools/test-safe.sh` as a pre-test gate so a tampered
# vendored grammar fails CI before the test suite has a chance to mask
# the change with an unrelated regression.
#
# Hash algorithm (must match `tools/generate-sbom.sh`):
#   if scanner.c present: sha256(parser.c || scanner.c)
#   else:                 sha256(parser.c)
#
# To re-pin after a deliberate grammar bump:
#   1. Vendor the new grammar into Sources/TreeSitterFooParser/
#   2. Run: ./tools/verify-grammar-hashes.sh --print
#   3. Paste the printed contentHash into GrammarManifest.swift
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/Sources/Indexer/GrammarManifest.swift"
PRINT_MODE=0

for arg in "$@"; do
    case "$arg" in
        --print) PRINT_MODE=1 ;;
        --help|-h)
            sed -n '2,/^set/p' "$0" | sed 's/^# //;s/^#//' | head -n -1
            exit 0
            ;;
        *)
            echo "verify-grammar-hashes.sh: unknown arg '$arg'" >&2
            exit 2
            ;;
    esac
done

if [ ! -f "$MANIFEST" ]; then
    echo "verify-grammar-hashes.sh: cannot find $MANIFEST" >&2
    exit 2
fi

# Pick a sha256 binary. macOS has `shasum`; Linux has `sha256sum`.
if command -v shasum >/dev/null 2>&1; then
    SHA_CMD=(shasum -a 256)
elif command -v sha256sum >/dev/null 2>&1; then
    SHA_CMD=(sha256sum)
else
    echo "verify-grammar-hashes.sh: need shasum or sha256sum" >&2
    exit 2
fi

compute_hash() {
    local dir="$1"
    if [ -f "$dir/scanner.c" ]; then
        cat "$dir/parser.c" "$dir/scanner.c" | "${SHA_CMD[@]}" | awk '{print $1}'
    else
        "${SHA_CMD[@]}" "$dir/parser.c" | awk '{print $1}'
    fi
}

# Parse the manifest. Each grammar entry has the shape:
#   "lang": GrammarInfo(
#       language: "lang",
#       ...
#       targetName: "TreeSitterFooParser",
#       contentHash: "abc..."
#   ),
#
# Pull (targetName, contentHash) pairs by single-pass awk.
parse_manifest() {
    awk '
        /targetName:/ {
            match($0, /"[^"]+"/)
            target = substr($0, RSTART+1, RLENGTH-2)
        }
        /contentHash:/ {
            match($0, /"[^"]+"/)
            hash = substr($0, RSTART+1, RLENGTH-2)
            if (target != "" && hash != "") {
                print target, hash
                target = ""; hash = ""
            }
        }
    ' "$MANIFEST"
}

declared_count=0
verified_count=0
mismatch_count=0
missing_count=0

while IFS=' ' read -r target declared; do
    [ -z "$target" ] && continue
    declared_count=$((declared_count + 1))
    dir="$REPO_ROOT/Sources/$target"
    if [ ! -d "$dir" ] || [ ! -f "$dir/parser.c" ]; then
        echo "MISSING  $target  (no $dir/parser.c)" >&2
        missing_count=$((missing_count + 1))
        continue
    fi
    actual=$(compute_hash "$dir")
    if [ "$PRINT_MODE" = "1" ]; then
        printf '%-32s %s\n' "$target" "$actual"
        verified_count=$((verified_count + 1))
        continue
    fi
    if [ "$actual" = "$declared" ]; then
        verified_count=$((verified_count + 1))
    else
        echo "MISMATCH $target" >&2
        echo "    declared:  $declared" >&2
        echo "    computed:  $actual" >&2
        mismatch_count=$((mismatch_count + 1))
    fi
done < <(parse_manifest)

if [ "$PRINT_MODE" = "1" ]; then
    echo "" >&2
    echo "printed $verified_count hashes (no verification performed)" >&2
    exit 0
fi

if [ "$declared_count" -eq 0 ]; then
    echo "verify-grammar-hashes.sh: no grammars parsed from manifest" >&2
    exit 2
fi

echo "grammars: $declared_count  verified: $verified_count  mismatched: $mismatch_count  missing: $missing_count" >&2

if [ "$mismatch_count" -gt 0 ] || [ "$missing_count" -gt 0 ]; then
    exit 1
fi

exit 0
