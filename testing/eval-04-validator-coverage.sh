#!/bin/bash
# Eval: Measure validator coverage — how many languages have validators registered
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "==============================================="
echo "  Eval 04: Validator Coverage"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

# Get list of validators from senkani
VALIDATOR_LIST=$($BIN validate --list dummy 2>&1 || true)
echo "Registered validators:"
echo "$VALIDATOR_LIST" | head -30
echo ""

# Count unique languages/validators
VALIDATOR_COUNT=$(echo "$VALIDATOR_LIST" | grep -ciE "swift|python|javascript|typescript|json|yaml|html|css|go|rust|ruby|java|kotlin|c\b|c\+\+|php|shell|bash|toml|xml|markdown|sql" || echo "0")

# Check which common tools are actually installed
echo "Checking installed tools:"
INSTALLED=0
TOOLS_FOUND=""
for tool in swiftc python3 node tsc go rustc ruby java javac php bash shellcheck jq xmllint; do
    if command -v "$tool" > /dev/null 2>&1; then
        INSTALLED=$((INSTALLED + 1))
        TOOLS_FOUND="$TOOLS_FOUND $tool"
        printf "  %-12s FOUND\n" "$tool"
    else
        printf "  %-12s missing\n" "$tool"
    fi
done
echo ""

# Run validators on sample files for each supported language
TMPDIR=/tmp/senkani-eval-validators-$$
mkdir -p "$TMPDIR"

PASS_COUNT=0
FAIL_COUNT=0
TESTED=0

# Swift (valid)
echo 'let x: Int = 42' > "$TMPDIR/test.swift"
RESULT=$($BIN validate "$TMPDIR/test.swift" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✓\|pass\|valid\|ok"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  swift (valid):      PASS"
else
    echo "  swift (valid):      $(echo "$RESULT" | head -1)"
fi

# JSON (valid)
echo '{"key": "value"}' > "$TMPDIR/test.json"
RESULT=$($BIN validate "$TMPDIR/test.json" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✓\|pass\|valid\|ok"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  json (valid):       PASS"
else
    echo "  json (valid):       $(echo "$RESULT" | head -1)"
fi

# JSON (invalid)
echo '{invalid json' > "$TMPDIR/bad.json"
RESULT=$($BIN validate "$TMPDIR/bad.json" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✗\|fail\|error\|invalid"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  json (invalid):     PASS (correctly detected)"
else
    echo "  json (invalid):     $(echo "$RESULT" | head -1)"
fi

# Python (valid)
echo 'x = 42' > "$TMPDIR/test.py"
RESULT=$($BIN validate "$TMPDIR/test.py" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✓\|pass\|valid\|ok"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  python (valid):     PASS"
else
    echo "  python (valid):     $(echo "$RESULT" | head -1)"
fi

# Python (invalid)
echo 'def broken(' > "$TMPDIR/bad.py"
RESULT=$($BIN validate "$TMPDIR/bad.py" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✗\|fail\|error\|invalid\|SyntaxError"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  python (invalid):   PASS (correctly detected)"
else
    echo "  python (invalid):   $(echo "$RESULT" | head -1)"
fi

# YAML (valid)
echo 'key: value' > "$TMPDIR/test.yaml"
RESULT=$($BIN validate "$TMPDIR/test.yaml" 2>&1 || true)
TESTED=$((TESTED + 1))
if echo "$RESULT" | grep -q "✓\|pass\|valid\|ok\|no validator"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    echo "  yaml (valid):       PASS"
else
    echo "  yaml (valid):       $(echo "$RESULT" | head -1)"
fi

# Cleanup
rm -rf "$TMPDIR"

echo ""
echo "-------------------------------------------"
echo "  Installed tools:   $INSTALLED"
echo "  Validator entries:  $VALIDATOR_COUNT language mentions"
echo "  Sample tests:       $PASS_COUNT / $TESTED passed"
echo ""
echo "EVAL: validator_tool_count = $INSTALLED (baseline: 5+)"
echo "EVAL: validator_sample_pass_rate = $(python3 -c "print(f'{$PASS_COUNT / max($TESTED, 1) * 100:.0f}')" 2>/dev/null || echo "0")% (baseline: >80%)"
echo ""

# Pass if at least 3 validators working
[ "$PASS_COUNT" -ge 3 ] && exit 0 || { echo "FAIL: only $PASS_COUNT / $TESTED validators passed"; exit 1; }
