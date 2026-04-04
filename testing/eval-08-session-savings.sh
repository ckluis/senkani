#!/bin/bash
# Eval: Simulate a 50-command coding session and measure total savings
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani
METRICS=/tmp/senkani-eval-session-$$.jsonl

echo "═══════════════════════════════════════════"
echo "  Eval 08: Simulated Session Savings"
echo "═══════════════════════════════════════════"
echo ""

# Prepare test data
python3 -c "for i in range(500): print(f'line {i}: ' + 'x' * 80)" > /tmp/senkani-eval-bigfile.txt
echo '{"name": "test", "valid": true}' > /tmp/senkani-eval-config.json

export SENKANI_METRICS_FILE="$METRICS"
rm -f "$METRICS"

echo "Running simulated session (50 commands)..."

# Simulated session
for i in $(seq 1 10); do
    $BIN exec -- git status > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- git -c color.ui=always log --oneline -20 > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- git -c color.ui=always diff HEAD~1 > /dev/null 2>&1 || true
done

for i in $(seq 1 10); do
    $BIN exec -- cat Sources/Shared/TokenFilter/BuiltinRules.swift > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- cat /tmp/senkani-eval-bigfile.txt > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- find Sources -name "*.swift" -type f > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- cat Package.swift > /dev/null 2>&1 || true
done

for i in $(seq 1 5); do
    $BIN exec -- echo "hello world" > /dev/null 2>&1 || true
done

echo ""
echo "Session metrics:"
$BIN stats --file "$METRICS" 2>&1

# Calculate dollar savings
TOTAL_RAW=$(python3 -c "
import json
raw = 0
for line in open('$METRICS'):
    d = json.loads(line)
    raw += d.get('rawBytes', 0)
print(raw)
" 2>/dev/null || echo "0")

TOTAL_FILTERED=$(python3 -c "
import json
filt = 0
for line in open('$METRICS'):
    d = json.loads(line)
    filt += d.get('filteredBytes', 0)
print(filt)
" 2>/dev/null || echo "0")

SAVED=$((TOTAL_RAW - TOTAL_FILTERED))
TOKENS_SAVED=$((SAVED / 4))

echo ""
echo "─────────────────────────────────────────"
echo "  Raw bytes:      $TOTAL_RAW"
echo "  Filtered bytes: $TOTAL_FILTERED"
echo "  Bytes saved:    $SAVED"
echo "  Est. tokens:    $TOKENS_SAVED"
echo "  Est. cost saved: \$$(python3 -c "print(f'{$TOKENS_SAVED / 1000000 * 3:.4f}')" 2>/dev/null || echo "?")"
echo ""

# Cleanup
rm -f "$METRICS" /tmp/senkani-eval-bigfile.txt /tmp/senkani-eval-config.json

# Pass if saved > 10000 bytes (conservative for 50 commands)
[ "$SAVED" -gt 10000 ] && exit 0 || { echo "FAIL: saved only $SAVED bytes (expected >10000)"; exit 1; }
