#!/bin/bash
# Eval: Self-improvement loop stub — capture current baseline numbers
# This is the foundation for making Senkani self-improving.
# Future: compare to previous baselines stored in a file and auto-adjust rules.
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "==============================================="
echo "  Eval 10: Self-Improvement Baseline Capture"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

BASELINE_DIR=.senkani/baselines
BASELINE_FILE="$BASELINE_DIR/eval-baselines.jsonl"
mkdir -p "$BASELINE_DIR"

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Running eval-01 (filter savings) to capture baseline..."
echo ""

# Run the core filter eval and capture metrics
TOTAL_RAW=0
TOTAL_FILTERED=0

measure() {
    local name="$1"
    shift
    local target_pct="$1"
    shift

    local raw_output
    raw_output=$("$@" 2>/dev/null || true)
    local raw_bytes=${#raw_output}

    local filtered_output
    filtered_output=$($BIN exec -- "$@" 2>/dev/null || true)
    local filtered_bytes=${#filtered_output}

    local saved=$((raw_bytes - filtered_bytes))
    local pct=0
    [ "$raw_bytes" -gt 0 ] && pct=$((saved * 100 / raw_bytes))

    printf "  %-30s %6dB -> %6dB  %3d%% saved\n" "$name" "$raw_bytes" "$filtered_bytes" "$pct"

    TOTAL_RAW=$((TOTAL_RAW + raw_bytes))
    TOTAL_FILTERED=$((TOTAL_FILTERED + filtered_bytes))

    # Write per-command baseline
    echo "{\"timestamp\":\"$TIMESTAMP\",\"command\":\"$name\",\"rawBytes\":$raw_bytes,\"filteredBytes\":$filtered_bytes,\"savedPct\":$pct,\"targetPct\":$target_pct}" >> "$BASELINE_FILE"
}

# Generate test data
python3 -c "for i in range(500): print(f'line {i}: ' + 'x' * 80)" > /tmp/senkani-eval-si-big.txt

# Run the same command families as eval-01
measure "git log (colored)" 5 git -c color.ui=always log --oneline -20
measure "git status (colored)" 5 git -c color.ui=always status
measure "cat large file" 70 cat /tmp/senkani-eval-si-big.txt
measure "find swift files" 0 find Sources -name "*.swift" -type f

rm -f /tmp/senkani-eval-si-big.txt

# Summary
TOTAL_SAVED=$((TOTAL_RAW - TOTAL_FILTERED))
[ "$TOTAL_RAW" -gt 0 ] && TOTAL_PCT=$((TOTAL_SAVED * 100 / TOTAL_RAW)) || TOTAL_PCT=0

echo ""
echo "-------------------------------------------"
echo "  Total: ${TOTAL_RAW}B raw -> ${TOTAL_FILTERED}B filtered (${TOTAL_PCT}% saved)"
echo ""

# Check if previous baselines exist
PREV_COUNT=0
if [ -f "$BASELINE_FILE" ]; then
    PREV_COUNT=$(wc -l < "$BASELINE_FILE" | tr -d ' ')
fi

echo "  Baseline file: $BASELINE_FILE"
echo "  Total entries: $PREV_COUNT"
echo ""

# Compare to previous run if available
if [ "$PREV_COUNT" -gt 4 ]; then
    echo "  Previous baselines found. Comparing..."
    python3 -c "
import json

entries = []
for line in open('$BASELINE_FILE'):
    try:
        entries.append(json.loads(line))
    except:
        pass

# Group by command, compare latest to earliest
from collections import defaultdict
by_cmd = defaultdict(list)
for e in entries:
    by_cmd[e['command']].append(e)

improved = 0
regressed = 0
same = 0

for cmd, runs in by_cmd.items():
    if len(runs) < 2:
        continue
    first = runs[0]['savedPct']
    last = runs[-1]['savedPct']
    delta = last - first
    if delta > 1:
        improved += 1
        print(f'    IMPROVED: {cmd} ({first}% -> {last}%)')
    elif delta < -1:
        regressed += 1
        print(f'    REGRESSED: {cmd} ({first}% -> {last}%)')
    else:
        same += 1

print(f'')
print(f'    Improved: {improved}, Regressed: {regressed}, Unchanged: {same}')
" 2>/dev/null || echo "    (comparison requires python3)"
fi

echo ""
echo "EVAL: self_improvement_baseline_pct = ${TOTAL_PCT}% (baseline: >30%)"
echo "EVAL: self_improvement_entries = $PREV_COUNT"
echo ""

# This eval always passes — it's a data capture step
exit 0
