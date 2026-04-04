#!/bin/bash
# Eval: Measure byte savings per command family
# This is the primary eval for proving the filter thesis.
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "═══════════════════════════════════════════"
echo "  Eval 01: Filter Savings by Command"
echo "═══════════════════════════════════════════"
echo ""

TOTAL_RAW=0
TOTAL_FILTERED=0

measure() {
    local name="$1"
    shift
    local target_pct="$1"
    shift

    # Run command and capture raw output size
    local raw_output
    raw_output=$("$@" 2>/dev/null || true)
    local raw_bytes=${#raw_output}

    # Run through senkani filter
    local filtered_output
    filtered_output=$($BIN exec -- "$@" 2>/dev/null || true)
    local filtered_bytes=${#filtered_output}

    local saved=$((raw_bytes - filtered_bytes))
    local pct=0
    [ "$raw_bytes" -gt 0 ] && pct=$((saved * 100 / raw_bytes))

    local status="PASS"
    [ "$pct" -lt "$target_pct" ] && status="MISS"

    printf "  %-30s %6dB → %6dB  %3d%% saved  (target: >%d%%)  %s\n" \
        "$name" "$raw_bytes" "$filtered_bytes" "$pct" "$target_pct" "$status"

    TOTAL_RAW=$((TOTAL_RAW + raw_bytes))
    TOTAL_FILTERED=$((TOTAL_FILTERED + filtered_bytes))
}

# Generate test data
python3 -c "for i in range(500): print(f'line {i}: ' + 'x' * 80)" > /tmp/senkani-eval-big.txt
echo '{"name": "test", "valid": true}' > /tmp/senkani-eval-small.json

# Run measurements
measure "git log (colored, 20 lines)" 5 git -c color.ui=always log --oneline -20
measure "git status (colored)" 5 git -c color.ui=always status
measure "cat large file (45KB)" 70 cat /tmp/senkani-eval-big.txt
measure "cat small file" 0 cat /tmp/senkani-eval-small.json
measure "find swift files" 0 find Sources -name "*.swift" -type f

# Cleanup
rm -f /tmp/senkani-eval-big.txt /tmp/senkani-eval-small.json

# Summary
echo ""
TOTAL_SAVED=$((TOTAL_RAW - TOTAL_FILTERED))
[ "$TOTAL_RAW" -gt 0 ] && TOTAL_PCT=$((TOTAL_SAVED * 100 / TOTAL_RAW)) || TOTAL_PCT=0
echo "─────────────────────────────────────────"
echo "  Total: ${TOTAL_RAW}B raw → ${TOTAL_FILTERED}B filtered (${TOTAL_PCT}% saved)"
echo ""

# Pass if overall savings > 30%
[ "$TOTAL_PCT" -ge 30 ] && exit 0 || { echo "FAIL: overall savings ${TOTAL_PCT}% < 30% target"; exit 1; }
