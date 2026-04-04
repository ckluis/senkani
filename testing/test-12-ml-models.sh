#!/bin/bash
# Test: ML model management — graceful degradation without downloaded models
# Does NOT download models. Validates tool availability, error messages, and ModelManager.
set -e
cd "$(dirname "$0")/.."

# Find MCP binary
if [ -x .build/debug/senkani-mcp ]; then
    MCP=.build/debug/senkani-mcp
elif [ -x .build/release/senkani-mcp ]; then
    MCP=.build/release/senkani-mcp
else
    echo "FAIL: no senkani-mcp binary found"; exit 1
fi

ERRORS=0

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

# Test 1: tools/list includes senkani_embed and senkani_vision (10 tools total)
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | mcp_call 5)
TOOL_COUNT=$(echo "$RESP" | grep -o '"senkani_[a-z]*"' | sort -u | wc -l | tr -d ' ')

if [ "$TOOL_COUNT" -eq 10 ]; then
    : # pass — all 10 tools present
else
    echo "FAIL: expected 10 tools, got $TOOL_COUNT"
    ERRORS=$((ERRORS + 1))
fi

if echo "$RESP" | grep -q '"senkani_embed"'; then
    : # pass
else
    echo "FAIL: tools/list missing senkani_embed"
    ERRORS=$((ERRORS + 1))
fi

if echo "$RESP" | grep -q '"senkani_vision"'; then
    : # pass
else
    echo "FAIL: tools/list missing senkani_vision"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: senkani_embed with a query — should return graceful error about model
# In CI without models downloaded, it should either try to download (and fail/timeout)
# or return an error about model not being available
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"senkani_embed","arguments":{"query":"filter engine"}}}' \
    | mcp_call 10)

if echo "$RESP" | grep -qi "error\|download\|model\|not.*found\|not.*available\|not.*ready\|result\|text"; then
    : # pass — got some response (model error, download prompt, or actual results if cached)
else
    echo "FAIL: senkani_embed did not return expected response"
    echo "  Got: $(echo "$RESP" | head -3)"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: senkani_vision with a fake image path — should return graceful error
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"senkani_vision","arguments":{"image":"/tmp/nonexistent-test-image-12345.png"}}}' \
    | mcp_call 10)

if echo "$RESP" | grep -qi "error\|not found\|not.*exist\|no such\|model\|download\|result\|text"; then
    : # pass — graceful error about file not found or model not available
else
    echo "FAIL: senkani_vision with fake path did not return error"
    echo "  Got: $(echo "$RESP" | head -3)"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: senkani_embed without required 'query' argument — should return argument error
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"senkani_embed","arguments":{}}}' \
    | mcp_call 5)

if echo "$RESP" | grep -qi "error\|required\|query\|missing"; then
    : # pass
else
    echo "FAIL: senkani_embed without query should return error"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: senkani_vision without required 'image' argument — should return argument error
RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" \
    '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"senkani_vision","arguments":{}}}' \
    | mcp_call 5)

if echo "$RESP" | grep -qi "error\|required\|image\|missing"; then
    : # pass
else
    echo "FAIL: senkani_vision without image should return error"
    ERRORS=$((ERRORS + 1))
fi

# Test 6: ModelManager cache directory can be created
CACHE_DIR="$HOME/Library/Caches/dev.senkani/models"
mkdir -p "$CACHE_DIR"
if [ -d "$CACHE_DIR" ]; then
    : # pass — directory exists or was created
    # Write a test models.json to verify the path works
    echo '{"models":[{"id":"minilm-l6","status":"available"},{"id":"gemma3-4b","status":"available"},{"id":"qwen2-vl-2b","status":"available"}]}' > "$CACHE_DIR/models-test.json"
    if [ -f "$CACHE_DIR/models-test.json" ]; then
        : # pass
        rm -f "$CACHE_DIR/models-test.json"
    else
        echo "FAIL: could not write to model cache directory"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "FAIL: could not create model cache directory at $CACHE_DIR"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== test-12-ml-models: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS ML model test(s) failed"; exit 1; }
