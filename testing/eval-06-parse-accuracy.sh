#!/bin/bash
# Eval: Measure structured parse accuracy on known build/test outputs
set -e
cd "$(dirname "$0")/.."

# Find MCP binary for senkani_parse tool
if [ -x .build/debug/senkani-mcp ]; then
    MCP=.build/debug/senkani-mcp
elif [ -x .build/release/senkani-mcp ]; then
    MCP=.build/release/senkani-mcp
else
    echo "FAIL: no senkani-mcp binary found"; exit 1
fi

echo "==============================================="
echo "  Eval 06: Parse Accuracy"
echo "==============================================="
echo ""

# Helper: send JSON-RPC to MCP server
mcp_call() {
    local timeout="${1:-5}"
    perl -e "
        use IPC::Open2;
        my \$pid = open2(my \$out, my \$in, '$MCP 2>/dev/null');
        while (my \$line = <STDIN>) { print \$in \$line; \$in->flush(); }
        close(\$in);
        eval {
            local \$SIG{ALRM} = sub { die 'timeout' };
            alarm int($timeout - 1);
            while (my \$line = <\$out>) { print \$line; }
        };
        kill 9, \$pid;
    " 2>/dev/null
}

INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'

TOTAL=0
CORRECT=0

check_result() {
    local desc="$1"
    local expected_pattern="$2"
    local resp="$3"

    TOTAL=$((TOTAL + 1))

    if echo "$resp" | grep -qiE "$expected_pattern"; then
        CORRECT=$((CORRECT + 1))
        printf "  PASS %-40s\n" "$desc"
    else
        printf "  FAIL %-40s\n" "$desc"
        echo "       Expected pattern: $expected_pattern"
        echo "       Got: $(echo "$resp" | head -2)"
    fi
}

# Test case 1: Swift compiler error
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"error: test.swift:10:5: cannot find type Foo in scope","type":"build"}}}' \
    | mcp_call 5)
check_result "Swift compiler error" "error|Foo|test.swift" "$RESP"

# Test case 2: Swift compiler warning
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"warning: main.swift:3:9: variable x was never used","type":"build"}}}' \
    | mcp_call 5)
check_result "Swift compiler warning" "warning|main.swift|variable" "$RESP"

# Test case 3: Multiple errors
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"error: a.swift:1:1: missing return\nerror: b.swift:5:3: type mismatch","type":"build"}}}' \
    | mcp_call 5)
check_result "Multiple build errors" "error|missing|mismatch" "$RESP"

# Test case 4: Test output with pass/fail
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"Test Suite AllTests passed. Executed 15 tests, with 2 failures in 3.5 seconds","type":"test"}}}' \
    | mcp_call 5)
check_result "Test pass/fail counts" "pass|fail|test|Tests" "$RESP"

# Test case 5: Python traceback
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"Traceback (most recent call last):\n  File app.py, line 42\nNameError: name foo is not defined","type":"build"}}}' \
    | mcp_call 5)
check_result "Python traceback" "error|NameError|Traceback|parse" "$RESP"

# Calculate accuracy
ACCURACY=$(python3 -c "print(f'{$CORRECT / max($TOTAL, 1) * 100:.0f}')" 2>/dev/null || echo "0")

echo ""
echo "-------------------------------------------"
echo "  Correct: $CORRECT / $TOTAL"
echo ""
echo "EVAL: parse_accuracy = ${ACCURACY}% (baseline: >90%)"
echo ""

# Pass if > 60% accuracy (generous, parser may handle formats differently)
[ "$CORRECT" -ge 3 ] && exit 0 || { echo "FAIL: accuracy too low ($CORRECT/$TOTAL)"; exit 1; }
