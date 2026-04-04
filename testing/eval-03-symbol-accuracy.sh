#!/bin/bash
# Eval: Measure symbol indexer precision and recall on the senkani project itself
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "==============================================="
echo "  Eval 03: Symbol Indexer Accuracy"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

# Index the project first
$BIN index --force > /dev/null 2>&1 || true

# Ground truth: symbols we know exist in this project
# Format: "SymbolName|expected_kind|expected_file_fragment"
GROUND_TRUTH=(
    "FilterEngine|class\|struct\|enum|FilterEngine.swift"
    "FilterPipeline|struct|FilterPipeline.swift"
    "SecretDetector|enum|SecretDetector.swift"
    "SessionMetrics|class\|struct|SessionMetrics.swift"
    "SymbolIndex|struct|SymbolIndex.swift"
    "ValidatorRegistry|class|ValidatorRegistry.swift"
    "MCPSession|class|MCPSession.swift"
    "ReadCache|class|ReadCache.swift"
    "ANSIStripper|enum|ANSIStripper.swift"
    "CommandMatcher|enum|CommandMatcher.swift"
)

TOTAL=${#GROUND_TRUTH[@]}
FOUND=0
CORRECT_KIND=0
CORRECT_FILE=0

for entry in "${GROUND_TRUTH[@]}"; do
    IFS='|' read -r symbol expected_kind expected_file <<< "$entry"

    RESULT=$($BIN search "$symbol" 2>&1 || true)

    if echo "$RESULT" | grep -qi "$symbol"; then
        FOUND=$((FOUND + 1))

        # Check kind
        if echo "$RESULT" | grep -qiE "$expected_kind"; then
            CORRECT_KIND=$((CORRECT_KIND + 1))
        else
            echo "  MISS kind: $symbol (expected $expected_kind)"
        fi

        # Check file
        if echo "$RESULT" | grep -qi "$expected_file"; then
            CORRECT_FILE=$((CORRECT_FILE + 1))
        else
            echo "  MISS file: $symbol (expected $expected_file)"
        fi
    else
        echo "  NOT FOUND: $symbol"
    fi
done

# Calculate metrics
RECALL=$(python3 -c "print(f'{$FOUND / $TOTAL * 100:.1f}')" 2>/dev/null || echo "0")
PRECISION_KIND=$(python3 -c "print(f'{$CORRECT_KIND / max($FOUND, 1) * 100:.1f}')" 2>/dev/null || echo "0")
PRECISION_FILE=$(python3 -c "print(f'{$CORRECT_FILE / max($FOUND, 1) * 100:.1f}')" 2>/dev/null || echo "0")

echo ""
echo "-------------------------------------------"
echo "  Found:         $FOUND / $TOTAL symbols"
echo "  Correct kind:  $CORRECT_KIND / $FOUND"
echo "  Correct file:  $CORRECT_FILE / $FOUND"
echo ""
echo "EVAL: symbol_recall = ${RECALL}% (baseline: >85%)"
echo "EVAL: symbol_kind_precision = ${PRECISION_KIND}% (baseline: >90%)"
echo "EVAL: symbol_file_precision = ${PRECISION_FILE}% (baseline: >90%)"
echo ""

# Pass if recall > 70% (generous for regex-based indexer)
[ "$FOUND" -ge 7 ] && exit 0 || { echo "FAIL: recall too low ($FOUND/$TOTAL)"; exit 1; }
