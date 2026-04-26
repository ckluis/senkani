#!/usr/bin/env bash
#
# generate-sbom.sh — Emit a CycloneDX 1.5 SBOM for senkani.
#
# Lists every shipped third-party component:
#   - 25 vendored tree-sitter grammars (with pinned content hashes
#     from `Sources/Indexer/GrammarManifest.swift`)
#   - MLX models declared in `Sources/Core/ModelManager.swift`
#     (downloaded at runtime; identified by HuggingFace repo + size)
#   - Swift packages from `Package.resolved` (with pinned commit SHAs)
#
# Output: CycloneDX 1.5 JSON to stdout, or the path given as $1.
# Deterministic: same input → byte-identical output. Components are
# sorted by name so diffs are reviewable.
#
# Wire into the release workflow when one lands (item
# luminary-2026-04-24-14-distribution-packaging). For local checks:
#   ./tools/generate-sbom.sh sbom.json
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$REPO_ROOT/Sources/Indexer/GrammarManifest.swift"
MODELS_FILE="$REPO_ROOT/Sources/Core/ModelManager.swift"
RESOLVED="$REPO_ROOT/Package.resolved"

OUT="${1:-/dev/stdout}"

# --- Project version (from CHANGELOG.md or VERSION file) ---
project_version="0.2.0"
if [ -f "$REPO_ROOT/VERSION" ]; then
    project_version=$(head -n1 "$REPO_ROOT/VERSION" | tr -d '[:space:]')
fi

# --- Timestamp (UTC, ISO-8601) ---
# Honor SOURCE_DATE_EPOCH for reproducible builds.
if [ -n "${SOURCE_DATE_EPOCH:-}" ]; then
    if date -u -r "$SOURCE_DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then
        TS=$(date -u -r "$SOURCE_DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")
    else
        TS=$(date -u -d "@$SOURCE_DATE_EPOCH" +"%Y-%m-%dT%H:%M:%SZ")
    fi
else
    TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
fi

# --- Generate components ---
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# 1) Tree-sitter grammars: parse (language, version, repo, hash) tuples.
awk '
    /language:/ {
        match($0, /"[^"]+"/)
        lang = substr($0, RSTART+1, RLENGTH-2)
    }
    /version:/ {
        match($0, /"[^"]+"/)
        ver = substr($0, RSTART+1, RLENGTH-2)
    }
    /repo:/ {
        match($0, /"[^"]+"/)
        repo = substr($0, RSTART+1, RLENGTH-2)
    }
    /contentHash:/ {
        match($0, /"[^"]+"/)
        hash = substr($0, RSTART+1, RLENGTH-2)
        if (lang != "" && ver != "" && repo != "" && hash != "") {
            print "GRAMMAR\t" lang "\t" ver "\t" repo "\t" hash
            lang=""; ver=""; repo=""; hash=""
        }
    }
' "$MANIFEST" >> "$TMP"

# 2) MLX models declared in ModelManager.swift.
awk '
    /id: "/ {
        match($0, /"[^"]+"/)
        id = substr($0, RSTART+1, RLENGTH-2)
    }
    /repoId: "/ {
        match($0, /"[^"]+"/)
        repo = substr($0, RSTART+1, RLENGTH-2)
    }
    /expectedSizeBytes:/ {
        # Strip the trailing comment, then keep only digits (drops "_").
        line = $0
        sub(/\/\/.*$/, "", line)
        gsub(/[^0-9]/, "", line)
        size = line
        if (id != "" && repo != "" && size != "") {
            print "MODEL\t" id "\t" repo "\t" size
            id=""; repo=""; size=""
        }
    }
' "$MODELS_FILE" >> "$TMP"

# 3) Swift packages from Package.resolved.
python3 - "$RESOLVED" "$TMP" <<'PY'
import json, sys
resolved_path, out_path = sys.argv[1], sys.argv[2]
with open(resolved_path) as f:
    data = json.load(f)
with open(out_path, "a") as out:
    for pin in data.get("pins", []):
        identity = pin.get("identity", "")
        location = pin.get("location", "")
        state = pin.get("state", {})
        version = state.get("version", "")
        revision = state.get("revision", "")
        # Branch-pinned packages have no version; fall back to revision[:12].
        if not version:
            version = "git-" + (revision[:12] if revision else "unknown")
        out.write(f"PACKAGE\t{identity}\t{version}\t{location}\t{revision}\n")
PY

# --- Render CycloneDX 1.5 JSON ---
python3 - "$TMP" "$project_version" "$TS" <<'PY' > "$OUT"
import json, sys, hashlib

tmp_path, project_version, ts = sys.argv[1], sys.argv[2], sys.argv[3]

components = []
with open(tmp_path) as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        kind = parts[0]
        if kind == "GRAMMAR":
            _, lang, ver, repo, content_hash = parts
            components.append({
                "type": "library",
                "bom-ref": f"pkg:tree-sitter/{lang}@{ver}",
                "group": "tree-sitter",
                "name": f"tree-sitter-{lang}",
                "version": ver,
                "purl": f"pkg:github/{repo}@v{ver}",
                "externalReferences": [
                    {"type": "vcs", "url": f"https://github.com/{repo}"}
                ],
                "hashes": [
                    {"alg": "SHA-256", "content": content_hash}
                ],
                "properties": [
                    {"name": "senkani:vendored", "value": "true"},
                    {"name": "senkani:component-class", "value": "tree-sitter-grammar"}
                ]
            })
        elif kind == "MODEL":
            _, model_id, repo, size = parts
            components.append({
                "type": "machine-learning-model",
                "bom-ref": f"pkg:huggingface/{repo}",
                "group": "huggingface",
                "name": model_id,
                "version": "downloaded-at-runtime",
                "purl": f"pkg:huggingface/{repo}",
                "externalReferences": [
                    {"type": "distribution",
                     "url": f"https://huggingface.co/{repo}"}
                ],
                "properties": [
                    {"name": "senkani:expected-size-bytes", "value": size},
                    {"name": "senkani:component-class", "value": "ml-model"}
                ]
            })
        elif kind == "PACKAGE":
            _, identity, version, location, revision = parts
            comp = {
                "type": "library",
                "bom-ref": f"pkg:swift/{identity}@{version}",
                "name": identity,
                "version": version,
                "purl": f"pkg:swift/{identity}@{version}",
                "externalReferences": [
                    {"type": "vcs", "url": location}
                ],
                "properties": [
                    {"name": "senkani:component-class", "value": "swift-package"}
                ]
            }
            if revision:
                comp["properties"].append(
                    {"name": "senkani:git-revision", "value": revision}
                )
            components.append(comp)

components.sort(key=lambda c: (c["properties"][-1]["value"] if False else c["name"], c["version"]))

# Stable serial number derived from the components themselves.
fingerprint = hashlib.sha256(
    json.dumps(components, sort_keys=True, separators=(",", ":")).encode()
).hexdigest()
serial = f"urn:uuid:{fingerprint[:8]}-{fingerprint[8:12]}-{fingerprint[12:16]}-{fingerprint[16:20]}-{fingerprint[20:32]}"

bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": serial,
    "version": 1,
    "metadata": {
        "timestamp": ts,
        "tools": [
            {"vendor": "senkani", "name": "generate-sbom.sh", "version": "1.0"}
        ],
        "component": {
            "type": "application",
            "bom-ref": f"pkg:senkani@{project_version}",
            "name": "senkani",
            "version": project_version
        }
    },
    "components": components
}

print(json.dumps(bom, indent=2, sort_keys=True))
PY
