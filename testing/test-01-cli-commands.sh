#!/bin/bash
# Test: All 11 CLI commands exist and respond
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

# Must build first
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

# Help and version
check "senkani --help" $BIN --help
check "senkani --version" $BIN --version

# exec
check "exec echo hello" $BIN exec -- echo hello

# exec preserves exit code
set +e
$BIN exec -- true 2>/dev/null; EC=$?; [ $EC -eq 0 ] || { echo "FAIL: exec true should exit 0, got $EC"; ERRORS=$((ERRORS+1)); }
$BIN exec -- false 2>/dev/null; EC=$?; [ $EC -ne 0 ] || { echo "FAIL: exec false should exit non-zero"; ERRORS=$((ERRORS+1)); }
set -e

# exec with flags
check "exec --no-filter" $BIN exec --no-filter -- echo test
check "exec --stats-only" $BIN exec --stats-only -- echo test

# index
check "index --force" $BIN index --force

# search
check "search Filter" $BIN search Filter

# fetch
check "fetch FilterEngine" $BIN fetch FilterEngine

# explore
check "explore Sources/Core" $BIN explore Sources/Core

# validate
check "validate --list" $BIN validate --list dummy

# compare
check "compare echo" $BIN compare -- echo hello

# stats (create a temp metrics file first)
TMPMETRICS=/tmp/senkani-test-cli-$$.jsonl
SENKANI_METRICS_FILE=$TMPMETRICS $BIN exec -- echo test 2>/dev/null || true
check "stats --file" $BIN stats --file "$TMPMETRICS"
rm -f "$TMPMETRICS"

# mcp-install (dry check — don't actually modify settings)
check "mcp-install --help" $BIN mcp-install --help

[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS test(s) failed"; exit 1; }
