#!/bin/bash
# Test: Hook script intercepts Read/Bash/Grep, respects toggles
set -e
cd "$(dirname "$0")/.."

HOOK=hooks/senkani-intercept.sh

# Must exist and be executable
if [ ! -x "$HOOK" ]; then
    echo "FAIL: $HOOK not found or not executable"
    exit 1
fi

ERRORS=0

# Test 1: Read tool call — should be blocked with senkani_read redirect
RESP=$(echo '{"tool_name":"Read","tool_input":{"file_path":"Package.swift"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '"decision".*block' && echo "$RESP" | grep -q 'senkani_read'; then
    : # pass
else
    echo "FAIL: Read not blocked with senkani_read redirect"
    echo "  Got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Bash read-only command — should be blocked with senkani_exec redirect
RESP=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '"decision".*block' && echo "$RESP" | grep -q 'senkani_exec'; then
    : # pass
else
    echo "FAIL: Bash (ls -la) not blocked with senkani_exec redirect"
    echo "  Got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: Bash write command (git commit) — should pass through
RESP=$(echo '{"tool_name":"Bash","tool_input":{"command":"git commit -m test"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: git commit should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: Bash with redirect (echo > file) — should pass through
RESP=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo test > /tmp/file"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: redirect command should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: Grep with simple symbol — should be blocked with senkani_search redirect
RESP=$(echo '{"tool_name":"Grep","tool_input":{"pattern":"MCPSession"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '"decision".*block' && echo "$RESP" | grep -q 'senkani_search'; then
    : # pass
else
    echo "FAIL: Grep(MCPSession) not blocked with senkani_search redirect"
    echo "  Got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 6: Grep with regex — should pass through
RESP=$(echo '{"tool_name":"Grep","tool_input":{"pattern":"func\\s+process"}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: regex grep should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 7: Unknown tool — should pass through
RESP=$(echo '{"tool_name":"Write","tool_input":{}}' | "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: unknown tool should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 8: SENKANI_INTERCEPT=off — all pass through
RESP=$(echo '{"tool_name":"Read","tool_input":{"file_path":"test"}}' | SENKANI_INTERCEPT=off "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: SENKANI_INTERCEPT=off should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 9: SENKANI_MODE=passthrough — all pass through
RESP=$(echo '{"tool_name":"Read","tool_input":{"file_path":"test"}}' | SENKANI_MODE=passthrough "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # pass
else
    echo "FAIL: SENKANI_MODE=passthrough should pass through, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

# Test 10: SENKANI_INTERCEPT_READ=off — Read passes, Bash still intercepted
RESP=$(echo '{"tool_name":"Read","tool_input":{"file_path":"test"}}' | SENKANI_INTERCEPT_READ=off "$HOOK" 2>/dev/null)
if echo "$RESP" | grep -q '^{}$\|^{ *}$'; then
    : # Read passed through
    RESP2=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | SENKANI_INTERCEPT_READ=off "$HOOK" 2>/dev/null)
    if echo "$RESP2" | grep -q '"decision".*block'; then
        : # Bash still intercepted
    else
        echo "FAIL: SENKANI_INTERCEPT_READ=off should still intercept Bash"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "FAIL: SENKANI_INTERCEPT_READ=off should pass through Read, got: $RESP"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== test-07-hooks: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS hook test(s) failed"; exit 1; }
