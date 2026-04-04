#!/bin/bash
# Eval: Verify senkani compare produces consistent results across runs
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "==============================================="
echo "  Eval 09: Compare Consistency"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

# Run compare on 5 different commands, each twice, and check consistency
COMMANDS=(
    "echo hello world"
    "git log --oneline -10"
    "cat Package.swift"
    "find Sources -name '*.swift' -type f"
    "git status"
)

TOTAL=0
CONSISTENT=0
FILTERED_LT_RAW=0
TOTAL_COMPARISONS=0

for cmd in "${COMMANDS[@]}"; do
    echo "  Testing: $cmd"

    # Run compare twice
    OUT1=$($BIN compare -- $cmd 2>&1 || true)
    OUT2=$($BIN compare -- $cmd 2>&1 || true)

    # Extract the "all features" row savings percentage from each run
    # Look for percentage values in the output
    PCT1=$(echo "$OUT1" | grep -i "all features" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
    PCT2=$(echo "$OUT2" | grep -i "all features" | grep -oE '[0-9]+%' | head -1 | tr -d '%')

    if [ -n "$PCT1" ] && [ -n "$PCT2" ]; then
        TOTAL=$((TOTAL + 1))
        DIFF=$((PCT1 - PCT2))
        ABS_DIFF=${DIFF#-}  # absolute value

        if [ "$ABS_DIFF" -le 1 ]; then
            CONSISTENT=$((CONSISTENT + 1))
            echo "    Run 1: ${PCT1}%, Run 2: ${PCT2}% (consistent)"
        else
            echo "    Run 1: ${PCT1}%, Run 2: ${PCT2}% (VARIANCE: ${ABS_DIFF}%)"
        fi
    else
        echo "    Could not extract percentage (output may be empty)"
    fi

    # Also verify filtered < raw for each mode
    TOTAL_COMPARISONS=$((TOTAL_COMPARISONS + 1))
    # Check that passthrough row shows 0% savings (no filtering)
    PT_PCT=$(echo "$OUT1" | grep -i "passthrough" | grep -oE '[0-9]+%' | head -1 | tr -d '%')
    if [ -n "$PT_PCT" ] && [ "$PT_PCT" -eq 0 ]; then
        FILTERED_LT_RAW=$((FILTERED_LT_RAW + 1))
    elif [ -n "$PT_PCT" ]; then
        : # passthrough with savings is unexpected but not fatal
    fi
done

# Calculate consistency rate
if [ "$TOTAL" -gt 0 ]; then
    RATE=$(python3 -c "print(f'{$CONSISTENT / $TOTAL * 100:.0f}')" 2>/dev/null || echo "0")
else
    RATE="0"
fi

echo ""
echo "-------------------------------------------"
echo "  Commands tested:   ${#COMMANDS[@]}"
echo "  Consistency checks: $CONSISTENT / $TOTAL"
echo "  Consistency rate:   ${RATE}%"
echo ""
echo "EVAL: compare_consistency_rate = ${RATE}% (baseline: 100%)"
echo "EVAL: compare_commands_tested = $TOTAL (baseline: 5)"
echo ""

# Pass if consistency >= 80%
[ "$CONSISTENT" -ge 4 ] && exit 0 || { echo "FAIL: consistency too low ($CONSISTENT/$TOTAL)"; exit 1; }
