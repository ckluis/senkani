#!/usr/bin/env bash
# WCAG 2.1 AA sweep of the Senkani docs site using pa11y-ci (HTML_CodeSniffer)
# and @axe-core/cli (axe-core 4.x). Drives Puppeteer's bundled Chrome for
# Testing — does not depend on /Applications/Chromium being installed.
#
# Usage:
#   ./scripts/a11y-check.sh                    # sweep every site URL
#   ./scripts/a11y-check.sh sample             # 18-page representative sample
#   ./scripts/a11y-check.sh urls <url-file>    # sweep only urls listed in file
#
# Outputs:
#   tools/website-checks/results/a11y/pa11y-<timestamp>.json
#   tools/website-checks/results/a11y/axe-<timestamp>.json
#   tools/website-checks/results/a11y/summary-<timestamp>.md
#
# Acceptance gate (per spec/website_rebuild_audit_round11.md):
#   0 AA violations + ≤3 warnings per page. Pages that fail the bar
#   are listed in the summary for follow-up rewrite filing.
set -euo pipefail

unset NODE_OPTIONS  # cmux harness sets a stale --require, which breaks node 25

root="$(cd "$(dirname "$0")/.." && pwd)"
checks="$root/tools/website-checks"
results="$checks/results/a11y"
mkdir -p "$results"
ts="$(date +%Y%m%d-%H%M%S)"
mode="${1:-all}"
port="${A11Y_PORT:-8765}"
base="http://127.0.0.1:${port}"

if ! curl -sf -o /dev/null "$base/index.html"; then
  echo "static server not responding at $base — start it with ./scripts/site-serve.sh start" >&2
  exit 2
fi

case "$mode" in
  sample)
    urls_file="$checks/sample-urls.txt"
    ;;
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
echo "a11y sweep: $count URLs ($mode)"
echo "results dir: $results"

# Generate pa11y-ci config — JSON file declaring the URL list + AA standard.
cfg="$checks/pa11y-ci.json"
{
  echo '{'
  echo '  "defaults": {'
  echo '    "standard": "WCAG2AA",'
  echo '    "timeout": 30000,'
  echo '    "wait": 200,'
  echo '    "chromeLaunchConfig": {"args": ["--no-sandbox"]}'
  echo '  },'
  echo '  "urls": ['
  awk 'NR>1{print ","} {printf "    \"%s\"", $0}' "$urls_file"
  echo
  echo '  ]'
  echo '}'
} > "$cfg"

cd "$checks"

# pa11y-ci sweep
pa11y_json="$results/pa11y-${ts}.json"
echo "→ pa11y-ci ..."
set +e
npx --no-install pa11y-ci --config "$cfg" --json > "$pa11y_json" 2> "$results/pa11y-${ts}.err"
pa11y_rc=$?
set -e
if [[ ! -s "$pa11y_json" ]]; then
  echo "pa11y-ci produced no JSON; see $results/pa11y-${ts}.err" >&2
  exit 1
fi

# axe-core sweep — runs axe-core 4.x via Puppeteer's bundled Chrome.
axe_json="$results/axe-${ts}.json"
echo "→ axe-core (puppeteer) ..."
set +e
node "$checks/run-axe.js" \
  --urls "$urls_file" \
  --out  "$axe_json" \
  > "$results/axe-${ts}.log" 2>&1
axe_rc=$?
set -e

# Summarize.
summary="$results/summary-${ts}.md"
node "$checks/summarize-a11y.js" \
  --pa11y "$pa11y_json" \
  --axe   "$axe_json" \
  --urls  "$urls_file" \
  > "$summary"

echo
echo "── Summary ──"
cat "$summary"
echo
echo "Wrote $summary"
echo "pa11y-ci exit: $pa11y_rc · axe exit: $axe_rc"
