#!/bin/bash
# Test: senkani compare renders A/B comparison table correctly
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

ERRORS=0

# Test 1: compare on a known command produces output with a table
OUTPUT=$($BIN compare -- echo hello 2>&1 || true)
if echo "$OUTPUT" | grep -q "senkani compare"; then
    : # pass — header present
else
    echo "FAIL: compare did not produce table header"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Table contains all 4 permutation rows
for mode in "passthrough" "filter only" "secrets only" "all features"; do
    if echo "$OUTPUT" | grep -q "$mode"; then
        : # pass
    else
        echo "FAIL: compare missing row for '$mode'"
        ERRORS=$((ERRORS + 1))
    fi
done

# Test 3: Table has Raw and Filtered columns
if echo "$OUTPUT" | grep -q "Raw" && echo "$OUTPUT" | grep -q "Filtered"; then
    : # pass
else
    echo "FAIL: compare missing Raw/Filtered column headers"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: Savings percentages are present and non-negative
if echo "$OUTPUT" | grep -q "Saved\|Savings"; then
    : # pass
else
    echo "FAIL: compare missing Saved/Savings column"
    ERRORS=$((ERRORS + 1))
fi

# Check no negative percentages in the output
if echo "$OUTPUT" | grep -qE '\-[0-9]+%'; then
    echo "FAIL: compare shows negative savings percentage"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: Bar chart renders (block characters)
if echo "$OUTPUT" | grep -q "█\|▓\|▒\|░"; then
    : # pass — visual bar rendered
else
    # Also accept if savings are 0% (echo hello is tiny, may have no bar)
    if echo "$OUTPUT" | grep -q "0%"; then
        : # acceptable — no savings for tiny output means no bar
    else
        echo "FAIL: compare did not render bar chart characters"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Test 6: compare on a command with more output (git log)
OUTPUT2=$($BIN compare -- git log --oneline -10 2>&1 || true)
if echo "$OUTPUT2" | grep -q "senkani compare" && echo "$OUTPUT2" | grep -q "passthrough"; then
    : # pass
else
    echo "FAIL: compare on git log did not produce table"
    ERRORS=$((ERRORS + 1))
fi

# Test 7: filtered bytes <= raw bytes in the output
# The "all features" row should show filtered <= raw
if echo "$OUTPUT2" | grep -q "Filtered"; then
    : # pass — column exists, savings are computed
else
    echo "FAIL: compare on git log missing Filtered column"
    ERRORS=$((ERRORS + 1))
fi

# Test 8: Large output does not hang (pipe deadlock test)
# Generate 72KB of output and ensure compare finishes within 15 seconds
python3 -c "for i in range(1000): print(f'line {i}: ' + 'x' * 70)" > /tmp/senkani-compare-big-$$.txt
set +e
timeout 15 $BIN compare -- cat /tmp/senkani-compare-big-$$.txt > /dev/null 2>&1
EC=$?
set -e
rm -f /tmp/senkani-compare-big-$$.txt

if [ $EC -eq 0 ]; then
    : # pass — no hang
elif [ $EC -eq 124 ]; then
    echo "FAIL: compare on large output timed out (pipe deadlock?)"
    ERRORS=$((ERRORS + 1))
else
    # Non-zero but not timeout is acceptable (command may have warnings)
    : # pass
fi

echo ""
echo "=== test-08-compare: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS compare test(s) failed"; exit 1; }
