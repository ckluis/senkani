#!/bin/bash
# Test: Metrics JSONL flow end-to-end via MCP server
# Verifies that tool calls produce valid JSONL metrics with correct fields.
set -e
cd "$(dirname "$0")/.."

# Find MCP binary
if [ -x .build/release/senkani-mcp ]; then
    MCP=.build/release/senkani-mcp
elif [ -x .build/debug/senkani-mcp ]; then
    MCP=.build/debug/senkani-mcp
else
    echo "FAIL: no senkani-mcp binary found"; exit 1
fi

ERRORS=0
METRICS_FILE="/tmp/senkani-test-metrics-$$.jsonl"

cleanup() {
    rm -f "$METRICS_FILE"
}
trap cleanup EXIT

# Helper: send JSON-RPC messages and capture responses
mcp_call() {
    local timeout="${1:-5}"
    SENKANI_METRICS_FILE="$METRICS_FILE" \
    perl -e "
        use IPC::Open2;
        \$ENV{'SENKANI_METRICS_FILE'} = '$METRICS_FILE';
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
READ_CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"senkani_read","arguments":{"path":"Package.swift"}}}'
EXEC_CALL='{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"senkani_exec","arguments":{"command":"echo hello"}}}'

# Send initialize + two tool calls
RESP=$(printf "%s\n%s\n%s\n%s\n" "$INIT" "$NOTIF" "$READ_CALL" "$EXEC_CALL" | mcp_call 10)

# Give a moment for file writes to flush
sleep 1

# Test 1: JSONL file exists
if [ ! -f "$METRICS_FILE" ]; then
    echo "FAIL: metrics file not created at $METRICS_FILE"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Has at least 2 lines (one per tool call)
if [ -f "$METRICS_FILE" ]; then
    LINE_COUNT=$(wc -l < "$METRICS_FILE" | tr -d ' ')
    if [ "$LINE_COUNT" -lt 2 ]; then
        echo "FAIL: expected 2+ lines in metrics file, got $LINE_COUNT"
        ERRORS=$((ERRORS + 1))
    fi
fi

# Test 3: Each line is valid JSON with required fields
if [ -f "$METRICS_FILE" ]; then
    LINENO_=0
    while IFS= read -r line; do
        LINENO_=$((LINENO_ + 1))
        [ -z "$line" ] && continue

        # Validate JSON and check required fields
        VALID=$(/usr/bin/python3 -c "
import sys, json
try:
    d = json.loads('''$line''')
    required = ['command', 'rawBytes', 'filteredBytes', 'savedBytes', 'savingsPercent', 'secretsFound', 'timestamp']
    missing = [f for f in required if f not in d]
    if missing:
        print('MISSING:' + ','.join(missing))
    elif d['rawBytes'] < d['filteredBytes']:
        print('INVARIANT:rawBytes < filteredBytes')
    else:
        print('OK')
except Exception as e:
    print('INVALID_JSON:' + str(e))
" 2>/dev/null)

        case "$VALID" in
            OK) ;;
            MISSING:*)
                echo "FAIL: line $LINENO_ missing fields: ${VALID#MISSING:}"
                ERRORS=$((ERRORS + 1))
                ;;
            INVARIANT:*)
                echo "FAIL: line $LINENO_ invariant violation: ${VALID#INVARIANT:}"
                ERRORS=$((ERRORS + 1))
                ;;
            INVALID_JSON:*)
                echo "FAIL: line $LINENO_ invalid JSON: ${VALID#INVALID_JSON:}"
                ERRORS=$((ERRORS + 1))
                ;;
            *)
                echo "FAIL: line $LINENO_ unexpected validation result: $VALID"
                ERRORS=$((ERRORS + 1))
                ;;
        esac
    done < "$METRICS_FILE"
fi

# Test 4: rawBytes >= filteredBytes for each entry (already checked above, but explicit)
if [ -f "$METRICS_FILE" ]; then
    BAD_ENTRIES=$(/usr/bin/python3 -c "
import json, sys
count = 0
for line in open('$METRICS_FILE'):
    line = line.strip()
    if not line: continue
    d = json.loads(line)
    if d['rawBytes'] < d['filteredBytes']:
        count += 1
print(count)
" 2>/dev/null)
    if [ "$BAD_ENTRIES" != "0" ]; then
        echo "FAIL: $BAD_ENTRIES entries have rawBytes < filteredBytes"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""
echo "=== test-10-metrics-flow: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS metrics test(s) failed"; exit 1; }
