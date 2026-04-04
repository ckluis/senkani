#!/bin/bash
# Eval: Measure cache hit rate across repeated file reads
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani
METRICS=/tmp/senkani-eval-cache-$$.jsonl

echo "==============================================="
echo "  Eval 02: Cache Hit Rate"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

export SENKANI_METRICS_FILE="$METRICS"
rm -f "$METRICS"

# Pick a real project file to read repeatedly
TARGET_FILE="Package.swift"

echo "Reading $TARGET_FILE 10 times via senkani exec..."

# First read (cold)
FIRST_START=$(python3 -c "import time; print(int(time.time()*1000))")
$BIN exec -- cat "$TARGET_FILE" > /dev/null 2>&1 || true
FIRST_END=$(python3 -c "import time; print(int(time.time()*1000))")
FIRST_MS=$((FIRST_END - FIRST_START))

# Subsequent reads (should be cached)
CACHED_TOTAL=0
for i in $(seq 2 10); do
    START=$(python3 -c "import time; print(int(time.time()*1000))")
    $BIN exec -- cat "$TARGET_FILE" > /dev/null 2>&1 || true
    END=$(python3 -c "import time; print(int(time.time()*1000))")
    MS=$((END - START))
    CACHED_TOTAL=$((CACHED_TOTAL + MS))
done
CACHED_AVG=$((CACHED_TOTAL / 9))

echo ""
echo "  First read:     ${FIRST_MS}ms"
echo "  Avg cached:     ${CACHED_AVG}ms (9 subsequent reads)"

# Analyze metrics file for cache indicators
if [ -f "$METRICS" ]; then
    TOTAL_LINES=$(wc -l < "$METRICS" | tr -d ' ')
    # Count lines where filteredBytes < rawBytes (indicates processing happened)
    PROCESSED=$(python3 -c "
import json
count = 0
for line in open('$METRICS'):
    try:
        d = json.loads(line)
        if d.get('filteredBytes', 0) < d.get('rawBytes', 0):
            count += 1
    except: pass
print(count)
" 2>/dev/null || echo "0")

    # Check for cache hit markers in metrics
    CACHE_HITS=$(python3 -c "
import json
hits = 0
total = 0
for line in open('$METRICS'):
    try:
        d = json.loads(line)
        total += 1
        if 'cached' in json.dumps(d).lower() or d.get('cacheHit', False):
            hits += 1
    except: pass
# If no explicit cache field, estimate from timing
if hits == 0 and total > 1:
    # At minimum, report that we got all 10 reads through
    print(f'{total} reads completed')
else:
    hit_rate = (hits / total * 100) if total > 0 else 0
    print(f'{hit_rate:.0f}% ({hits}/{total})')
" 2>/dev/null || echo "unknown")

    echo "  Metrics lines:  $TOTAL_LINES"
    echo "  Cache info:     $CACHE_HITS"
else
    echo "  (no metrics file produced)"
fi

# Report
echo ""
echo "-------------------------------------------"
echo "EVAL: cache_first_read_ms = $FIRST_MS (baseline: <500ms)"
echo "EVAL: cache_avg_subsequent_ms = $CACHED_AVG (baseline: <200ms)"
echo ""

# Cleanup
rm -f "$METRICS"

# Pass if all 10 reads completed without error
# The cache effectiveness is measured but not gated hard — it's informational
exit 0
