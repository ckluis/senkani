#!/bin/bash
# Test: GUI app launches, stays running, terminates cleanly
set -e
cd "$(dirname "$0")/.."
APP=.build/debug/SenkaniApp
ERRORS=0

[ -x "$APP" ] || { echo "Building SenkaniApp..."; swift build --target SenkaniApp 2>&1 | tail -1; }
[ -x "$APP" ] || { echo "FAIL: SenkaniApp binary not found"; exit 1; }

# Launch in background
$APP &
PID=$!

# Wait 3 seconds
sleep 3

# Check if still running
if ps -p $PID > /dev/null 2>&1; then
    : # pass — app is running
else
    echo "FAIL: SenkaniApp crashed within 3 seconds"
    ERRORS=$((ERRORS + 1))
fi

# Clean termination
kill $PID 2>/dev/null
sleep 1

if ps -p $PID > /dev/null 2>&1; then
    kill -9 $PID 2>/dev/null
    echo "WARN: app required SIGKILL (didn't terminate on SIGTERM)"
fi

[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS GUI test(s) failed"; exit 1; }
