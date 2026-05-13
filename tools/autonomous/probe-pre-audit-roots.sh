#!/usr/bin/env bash
#
# probe-pre-audit-roots.sh — round-time smoke check for the
# /senkani-autonomous skill's pre-audit search-root derivation.
#
# Prints the resolved root set to stdout and asserts that
# `SenkaniApp/` is in the set. Exits non-zero if the assertion fails
# (CI-callable; safe to run from a fresh shell).
#
# The skill itself runs the derivation in-context (parsing
# Package.swift, listing *.xcodeproj, reading the manifest). This
# script is the operator-runnable mirror — useful when validating a
# manifest edit or eyeballing what the next round will grep.
#
# Derivation layers (matches SKILL.md `## Pre-audit search roots`):
#   1. Package.swift target `path:` directives → top-level dir of each.
#      SwiftPM-convention paths (`Sources/<Name>`, `Tests/<Name>`) for
#      targets without an explicit `path:` are covered by the
#      `Sources` and `Tests` defaults pulled in below.
#   2. Repo-root `*.xcodeproj` peer dirs (basename-without-.xcodeproj).
#   3. Optional manifest override `pre_audit.source_roots: [...]`.
#
# Usage:
#   tools/autonomous/probe-pre-audit-roots.sh         # print + assert
#   tools/autonomous/probe-pre-audit-roots.sh --quiet # exit code only

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PACKAGE_SWIFT="$REPO_ROOT/Package.swift"
MANIFEST="$REPO_ROOT/spec/autonomous-manifest.yaml"
QUIET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=1; shift ;;
        -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$PACKAGE_SWIFT" ]]; then
    echo "Package.swift not found: $PACKAGE_SWIFT" >&2
    exit 1
fi

# Layer 1 — Package.swift explicit `path:` directives.
# Match `path: "Foo/Bar"` lines; capture the quoted value; take the
# top-level dir component (everything before the first `/`, or the
# whole value if no slash).
layer1=$(grep -hoE 'path:[[:space:]]*"[^"]+"' "$PACKAGE_SWIFT" \
         | sed -E 's/path:[[:space:]]*"([^"]+)"/\1/' \
         | awk -F/ '{print $1}' \
         | sort -u)

# Layer 2 — repo-root *.xcodeproj peer dirs (no-ops on senkani).
layer2=""
shopt -s nullglob
for proj in "$REPO_ROOT"/*.xcodeproj; do
    basename "$proj" .xcodeproj
done > /tmp/.probe-pre-audit-layer2.$$ || true
layer2=$(sort -u < /tmp/.probe-pre-audit-layer2.$$)
rm -f /tmp/.probe-pre-audit-layer2.$$

# Layer 3 — manifest pre_audit.source_roots (optional union).
# Treat missing block or empty list as no-op. Portable parse: pull
# the inline list contents between [ and ] on the source_roots line
# (only inline-array form is supported here; block-form is parsed
# by the skill's in-context YAML reader).
layer3=""
if [[ -f "$MANIFEST" ]]; then
    raw=$(awk '
        /^pre_audit:/             { in_block=1; next }
        in_block && /^[a-zA-Z]/   { in_block=0 }
        in_block && /^[[:space:]]+source_roots:/ { print; in_block=0 }
    ' "$MANIFEST" \
        | sed -E 's/.*\[//; s/\].*//' \
        | tr ',' '\n' \
        | sed -E 's/^[[:space:]"\x27]+//; s/[[:space:]"\x27]+$//' \
        | grep -v '^$' || true)
    layer3=$(printf '%s\n' "$raw" | awk -F/ '{print $1}' | sort -u)
fi

# Union all layers, dedupe.
resolved=$(printf '%s\n%s\n%s\n' "$layer1" "$layer2" "$layer3" \
           | grep -v '^$' \
           | sort -u)

if [[ -z "$QUIET" ]]; then
    echo "# Pre-audit search roots (resolved at $(date -u +%FT%TZ))"
    echo "# Layer 1 — Package.swift target path:"
    echo "$layer1" | sed 's/^/  /'
    echo "# Layer 2 — repo-root *.xcodeproj peer dirs:"
    if [[ -n "$layer2" ]]; then
        echo "$layer2" | sed 's/^/  /'
    else
        echo "  (none)"
    fi
    echo "# Layer 3 — manifest pre_audit.source_roots:"
    if [[ -n "$layer3" ]]; then
        echo "$layer3" | sed 's/^/  /'
    else
        echo "  (empty)"
    fi
    echo "# Resolved set (unioned, deduped):"
    echo "$resolved" | sed 's/^/  /'
fi

# Assertion: SenkaniApp must be in the resolved set.
if ! grep -qx 'SenkaniApp' <<< "$resolved"; then
    echo "FAIL: 'SenkaniApp' not in resolved pre-audit root set" >&2
    echo "      Pre-audit greps will miss SenkaniApp/ writers." >&2
    echo "      Fix: ensure Package.swift declares the SenkaniApp" >&2
    echo "      target with path: \"SenkaniApp\", OR pin it via" >&2
    echo "      spec/autonomous-manifest.yaml pre_audit.source_roots." >&2
    exit 1
fi

[[ -z "$QUIET" ]] && echo "PASS: SenkaniApp/ present in resolved root set."
exit 0
