#!/usr/bin/env bash
# Preview the senkani website locally.
#
# Directory-style URLs (e.g. `docs/guides/install/`) require a real
# HTTP server — they do NOT work over file:// because browsers don't
# auto-serve index.html for directory URIs under file://.
#
# GitHub Pages handles directory URLs correctly on deploy.
#
# Usage: ./scripts/preview.sh [port]
set -euo pipefail
cd "$(dirname "$0")/.."
PORT="${1:-8080}"
echo "Serving senkani website at http://localhost:${PORT}/"
echo "Ctrl-C to stop."
exec python3 -m http.server "$PORT"
