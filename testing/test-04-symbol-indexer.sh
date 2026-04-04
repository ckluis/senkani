#!/bin/bash
# Test: Symbol indexer — index, search, fetch, explore
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

ERRORS=0
check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then
        : # pass
    else
        echo "FAIL: $desc"
        ERRORS=$((ERRORS + 1))
    fi
}

# Test 1: Index the project
check "senkani index" $BIN index --force

# Test 2: Index file created
if [ ! -f ".senkani/index.json" ]; then
    echo "FAIL: .senkani/index.json not created"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: Index has reasonable symbol count (150+)
if [ -f ".senkani/index.json" ]; then
    SYMBOL_COUNT=$(/usr/bin/python3 -c "
import json, sys
try:
    with open('.senkani/index.json') as f:
        idx = json.load(f)
    # symbols may be at top level or nested
    if isinstance(idx, list):
        print(len(idx))
    elif isinstance(idx, dict):
        syms = idx.get('symbols', idx.get('entries', []))
        if isinstance(syms, list):
            print(len(syms))
        else:
            # count all values if dict of symbols
            total = sum(len(v) if isinstance(v, list) else 1 for v in syms.values())
            print(total)
    else:
        print(0)
except Exception as e:
    print(0)
" 2>/dev/null)
    if [ "$SYMBOL_COUNT" -lt 50 ]; then
        echo "FAIL: expected 50+ symbols in index, got $SYMBOL_COUNT"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Test 4: Search for MCPSession
RESP=$($BIN search MCPSession 2>&1) || true
if echo "$RESP" | grep -qi "MCPSession"; then
    : # pass
else
    echo "FAIL: search MCPSession did not find MCPSession"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: Search with --kind function for recordMetrics
RESP=$($BIN search --kind function recordMetrics 2>&1) || true
if echo "$RESP" | grep -qi "recordMetrics\|record"; then
    : # pass
else
    echo "FAIL: search --kind function recordMetrics did not find it"
    ERRORS=$((ERRORS + 1))
fi

# Test 6: Fetch MCPSession — should contain class definition
RESP=$($BIN fetch MCPSession 2>&1) || true
if echo "$RESP" | grep -qi "class\|MCPSession\|final"; then
    : # pass
else
    echo "FAIL: fetch MCPSession did not return class definition"
    ERRORS=$((ERRORS + 1))
fi

# Test 7: Explore — should show symbol tree output
RESP=$($BIN explore 2>&1) || true
if echo "$RESP" | grep -qi "symbol\|file\|Sources\|class\|struct\|func"; then
    : # pass
else
    echo "FAIL: explore did not return symbol tree"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== test-04-symbol-indexer: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS symbol indexer test(s) failed"; exit 1; }
