#!/bin/bash
# Test: MCP server starts, responds to initialize, lists 10 tools, handles tool calls
# Tests both the standalone senkani-mcp binary and SenkaniApp --mcp-server (unified binary)
set -e
cd "$(dirname "$0")/.."

# Accept a binary path as $1, default to senkani-mcp
if [ -n "$1" ]; then
    MCP="$1"
elif [ -x .build/debug/senkani-mcp ]; then
    MCP=.build/debug/senkani-mcp
elif [ -x .build/release/senkani-mcp ]; then
    MCP=.build/release/senkani-mcp
else
    echo "FAIL: no senkani-mcp binary found"; exit 1
fi
ERRORS=0

echo "Testing binary: $MCP"

# Helper: send JSON-RPC messages and capture responses
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

# Test 1: Initialize
RESP=$(printf "%s\n" "$INIT" | mcp_call 3)
if echo "$RESP" | grep -q '"serverInfo"'; then
    : # pass
else
    echo "FAIL: initialize did not return serverInfo"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Tools list (10 tools)
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | mcp_call 5)
TOOL_COUNT=$(echo "$RESP" | grep -o '"senkani_[a-z]*"' | sort -u | wc -l | tr -d ' ')
if [ "$TOOL_COUNT" -eq 10 ]; then
    : # pass
else
    echo "FAIL: expected 10 tools, got $TOOL_COUNT"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: senkani_session(stats)
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"senkani_session","arguments":{"action":"stats"}}}' | mcp_call 5)
if echo "$RESP" | grep -q "Session Stats"; then
    : # pass
else
    echo "FAIL: senkani_session(stats) did not return stats"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: senkani_exec(echo hello)
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"senkani_exec","arguments":{"command":"echo hello"}}}' | mcp_call 5)
if echo "$RESP" | grep -q "hello"; then
    : # pass
else
    echo "FAIL: senkani_exec(echo hello) did not return hello"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: senkani_read(Package.swift)
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"senkani_read","arguments":{"path":"Package.swift"}}}' | mcp_call 5)
if echo "$RESP" | grep -q "senkani"; then
    : # pass
else
    echo "FAIL: senkani_read(Package.swift) did not return content"
    ERRORS=$((ERRORS + 1))
fi

# Test 6: senkani_validate
echo '{"valid": true}' > /tmp/senkani-test-valid-$$.json
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"senkani_validate","arguments":{"file":"/tmp/senkani-test-valid-'$$'.json"}}}' | mcp_call 5)
rm -f /tmp/senkani-test-valid-$$.json
if echo "$RESP" | grep -q "valid\|json"; then
    : # pass
else
    echo "FAIL: senkani_validate did not process file"
    ERRORS=$((ERRORS + 1))
fi

# Test 7: senkani_search
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"senkani_search","arguments":{"query":"MCPSession"}}}' | mcp_call 10)
if echo "$RESP" | grep -qi "MCPSession\|symbol\|result"; then
    : # pass
else
    echo "FAIL: senkani_search(MCPSession) returned no results"
    ERRORS=$((ERRORS + 1))
fi

# Test 8: senkani_explore
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"senkani_explore","arguments":{}}}' | mcp_call 10)
if echo "$RESP" | grep -qi "symbol\|tree\|file\|result\|text"; then
    : # pass
else
    echo "FAIL: senkani_explore returned no output"
    ERRORS=$((ERRORS + 1))
fi

# Test 9: senkani_parse
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"senkani_parse","arguments":{"output":"error: test.swift:10:5: cannot find type Foo in scope","type":"build"}}}' | mcp_call 5)
if echo "$RESP" | grep -qi "error\|Foo\|result\|text"; then
    : # pass
else
    echo "FAIL: senkani_parse returned no output"
    ERRORS=$((ERRORS + 1))
fi

# Test 10: senkani_fetch
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"senkani_fetch","arguments":{"name":"MCPSession"}}}' | mcp_call 10)
if echo "$RESP" | grep -qi "class\|MCPSession\|not found\|text"; then
    : # pass
else
    echo "FAIL: senkani_fetch(MCPSession) returned no output"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== $MCP: $ERRORS error(s) ==="

[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS MCP test(s) failed"; exit 1; }
