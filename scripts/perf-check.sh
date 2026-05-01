#!/usr/bin/env bash
# Lighthouse perf sweep against a local static server, throttled to a
# Moto G Power profile on slow 3G — the mid-tier baseline declared in
# spec/website_rebuild_audit_round11.md.
#
# Usage:
#   ./scripts/perf-check.sh                    # sweep every site URL
#   ./scripts/perf-check.sh sample             # representative sample
#   ./scripts/perf-check.sh urls <url-file>    # sweep only urls listed
#
# Outputs:
#   tools/website-checks/results/perf/lighthouse-<timestamp>/<page>.json
#   tools/website-checks/results/perf/summary-<timestamp>.md
#
# Acceptance gate: perf score ≥90 per page. Any page below 90 is
# listed in the summary for follow-up rewrite filing.
set -euo pipefail

unset NODE_OPTIONS

# Point chrome-launcher (used by lighthouse) at puppeteer's Chrome for Testing —
# avoids the macOS Gatekeeper block on /Applications/Chromium.
export CHROME_PATH="${CHROME_PATH:-/Users/$(whoami)/.cache/puppeteer/chrome/mac_arm-147.0.7727.57/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing}"

root="$(cd "$(dirname "$0")/.." && pwd)"
checks="$root/tools/website-checks"
results="$checks/results/perf"
mkdir -p "$results"
ts="$(date +%Y%m%d-%H%M%S)"
out_dir="$results/lighthouse-${ts}"
mkdir -p "$out_dir"
mode="${1:-all}"
port="${PERF_PORT:-8765}"
base="http://127.0.0.1:${port}"

if ! curl -sf -o /dev/null "$base/index.html"; then
  echo "static server not responding at $base — start it with ./scripts/site-serve.sh start" >&2
  exit 2
fi

case "$mode" in
  sample) urls_file="$checks/sample-urls.txt" ;;
  urls)
    urls_file="${2:-}"
    [[ -z "$urls_file" || ! -f "$urls_file" ]] && { echo "usage: $0 urls <file>" >&2; exit 2; }
    ;;
  all|*)
    urls_file="$checks/all-urls.txt"
    cd "$root"
    find . -name "*.html" \
      -not -path "./node_modules/*" \
      -not -path "./tools/*" \
      -not -path "./.build/*" \
      -not -path "./testing/*" \
      | sed "s|^\\./|$base/|" \
      | sort > "$urls_file"
    ;;
esac

count="$(wc -l < "$urls_file" | tr -d ' ')"
echo "perf sweep: $count URLs ($mode)"
echo "results dir: $out_dir"

cd "$checks"
i=0
while read -r url; do
  i=$((i+1))
  slug="$(echo "$url" | sed -E "s|^http://127.0.0.1:[0-9]+/||; s|[/.]|_|g; s|_html$||")"
  [[ -z "$slug" ]] && slug="root"
  printf '  [%d/%d] %-50s ' "$i" "$count" "$slug"
  npx --no-install lighthouse "$url" \
    --quiet \
    --chrome-flags="--headless=new --no-sandbox" \
    --form-factor=mobile \
    --throttling-method=simulate \
    --throttling.cpuSlowdownMultiplier=4 \
    --throttling.rttMs=150 \
    --throttling.throughputKbps=1638 \
    --only-categories=performance \
    --output=json \
    --output-path="$out_dir/${slug}.json" \
    >/dev/null 2>>"$out_dir/lighthouse.err" \
    && echo "ok" || echo "FAIL (see lighthouse.err)"
done < "$urls_file"

summary="$results/summary-${ts}.md"
node "$checks/summarize-perf.js" \
  --dir "$out_dir" \
  --urls "$urls_file" \
  > "$summary"

echo
echo "── Summary ──"
cat "$summary"
echo
echo "Wrote $summary"
