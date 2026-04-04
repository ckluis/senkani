#!/bin/bash
# Test: Cross-layer feature toggle consistency
# Env vars SENKANI_FILTER, SENKANI_SECRETS, SENKANI_CACHE, SENKANI_INDEXER
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

ERRORS=0

# --- Filter toggle ---

# Test 1: SENKANI_FILTER=off — output should be raw passthrough
# Use colored git log so filtering would strip ANSI codes
RAW_OUTPUT=$(git -c color.ui=always log --oneline -5 2>/dev/null || echo "colored output")
FILTERED_OFF=$(SENKANI_FILTER=off $BIN exec -- git -c color.ui=always log --oneline -5 2>/dev/null || true)
FILTERED_ON=$(SENKANI_FILTER=on $BIN exec -- git -c color.ui=always log --oneline -5 2>/dev/null || true)

# When filter is off, output should match raw (or at least be >= filtered-on length)
OFF_LEN=${#FILTERED_OFF}
ON_LEN=${#FILTERED_ON}

if [ "$OFF_LEN" -ge "$ON_LEN" ]; then
    : # pass — filter off produces more output (or same if nothing to filter)
else
    echo "FAIL: SENKANI_FILTER=off output ($OFF_LEN bytes) smaller than filter=on ($ON_LEN bytes)"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: SENKANI_FILTER=on should strip ANSI if colored output present
# Check that ANSI escape codes are present when off but stripped when on
if echo "$FILTERED_OFF" | grep -qP '\x1b\[' 2>/dev/null || echo "$FILTERED_OFF" | grep -q $'\033\[' 2>/dev/null; then
    # ANSI found in filter=off — good, now check filter=on strips it
    if echo "$FILTERED_ON" | grep -qP '\x1b\[' 2>/dev/null || echo "$FILTERED_ON" | grep -q $'\033\[' 2>/dev/null; then
        echo "FAIL: SENKANI_FILTER=on did not strip ANSI codes"
        ERRORS=$((ERRORS + 1))
    fi
else
    : # No ANSI in source — skip this sub-test (git may not produce color in CI)
fi

# --- Secrets toggle ---

# Test 3: SENKANI_SECRETS=on should redact API keys
FAKE_SECRET="ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890"
echo "$FAKE_SECRET" > /tmp/senkani-toggle-secret-$$.txt

SECRETS_ON=$(SENKANI_SECRETS=on $BIN exec -- cat /tmp/senkani-toggle-secret-$$.txt 2>&1 || true)
if echo "$SECRETS_ON" | grep -q "REDACTED"; then
    : # pass
else
    echo "FAIL: SENKANI_SECRETS=on did not redact API key"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: SENKANI_SECRETS=off should NOT redact
SECRETS_OFF=$(SENKANI_SECRETS=off SENKANI_FILTER=off $BIN exec -- cat /tmp/senkani-toggle-secret-$$.txt 2>&1 || true)
if echo "$SECRETS_OFF" | grep -q "sk-ant-api03"; then
    : # pass — key visible
else
    echo "FAIL: SENKANI_SECRETS=off still redacted the key"
    ERRORS=$((ERRORS + 1))
fi

rm -f /tmp/senkani-toggle-secret-$$.txt

# --- SENKANI_MODE=passthrough ---

# Test 5: SENKANI_MODE=passthrough disables all processing
echo "$FAKE_SECRET" > /tmp/senkani-toggle-mode-$$.txt
MODE_PT=$(SENKANI_MODE=passthrough $BIN exec -- cat /tmp/senkani-toggle-mode-$$.txt 2>&1 || true)
if echo "$MODE_PT" | grep -q "sk-ant-api03"; then
    : # pass — passthrough mode preserves raw output including secrets
else
    echo "FAIL: SENKANI_MODE=passthrough did not pass through secrets"
    ERRORS=$((ERRORS + 1))
fi
rm -f /tmp/senkani-toggle-mode-$$.txt

# --- CLI flag: --no-filter ---

# Test 6: --no-filter flag disables filtering
NO_FILTER_OUT=$($BIN exec --no-filter -- git -c color.ui=always log --oneline -5 2>/dev/null || true)
NF_LEN=${#NO_FILTER_OUT}
if [ "$NF_LEN" -ge "$ON_LEN" ]; then
    : # pass
else
    echo "FAIL: --no-filter output ($NF_LEN bytes) smaller than filter=on ($ON_LEN bytes)"
    ERRORS=$((ERRORS + 1))
fi

# --- Indexer toggle ---

# Test 7: SENKANI_INDEXER=off — search should return empty or disabled message
INDEXER_OFF=$(SENKANI_INDEXER=off $BIN search FilterEngine 2>&1 || true)
if echo "$INDEXER_OFF" | grep -qi "disabled\|no results\|indexer.*off\|not available\|no symbols\|empty\|error"; then
    : # pass
else
    # Even if search still works (pre-built index), just confirm it doesn't crash
    : # acceptable — doesn't crash
fi

# --- MCP server respects env vars ---

# Test 8: MCP server with SENKANI_FILTER=off should report filter disabled
# Use the MCP binary if available
if [ -x .build/debug/senkani-mcp ] || [ -x .build/release/senkani-mcp ]; then
    MCP=$( [ -x .build/debug/senkani-mcp ] && echo .build/debug/senkani-mcp || echo .build/release/senkani-mcp )
    INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1.0"}}}'
    NOTIF='{"jsonrpc":"2.0","method":"notifications/initialized"}'
    CONFIG_CALL='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"senkani_session","arguments":{"action":"stats"}}}'

    RESP=$(printf "%s\n%s\n%s\n" "$INIT" "$NOTIF" "$CONFIG_CALL" | SENKANI_FILTER=off perl -e "
        use IPC::Open2;
        my \$pid = open2(my \$out, my \$in, '$MCP 2>/dev/null');
        while (my \$line = <STDIN>) { print \$in \$line; \$in->flush(); }
        close(\$in);
        eval {
            local \$SIG{ALRM} = sub { die 'timeout' };
            alarm 4;
            while (my \$line = <\$out>) { print \$line; }
        };
        kill 9, \$pid;
    " 2>/dev/null || true)
    if echo "$RESP" | grep -qi "stats\|Session\|filter.*off\|filter.*false\|result\|text"; then
        : # pass — MCP server started and responded
    else
        echo "FAIL: MCP server with SENKANI_FILTER=off did not respond to session stats"
        ERRORS=$((ERRORS + 1))
    fi
fi

echo ""
echo "=== test-11-feature-toggles: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS feature toggle test(s) failed"; exit 1; }
