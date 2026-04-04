#!/bin/bash
# Test: Validator registry — detect and validate across languages
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

ERRORS=0

cleanup() {
    rm -f /tmp/senkani-test-bad-$$.swift /tmp/senkani-test-good-$$.swift
    rm -f /tmp/senkani-test-bad-$$.json /tmp/senkani-test-good-$$.json
}
trap cleanup EXIT

# Test 1: --list shows installed validators
RESP=$($BIN validate --list dummy 2>&1) || true
if echo "$RESP" | grep -qi "swift\|json\|validator\|syntax\|type"; then
    : # pass
else
    echo "FAIL: validate --list did not show validators"
    ERRORS=$((ERRORS + 1))
fi

# Test 2: Invalid Swift file (syntax error)
cat > /tmp/senkani-test-bad-$$.swift << 'SWIFT'
func broken( {
    let x: Int = "not an int"
}
SWIFT

set +e
RESP=$($BIN validate /tmp/senkani-test-bad-$$.swift 2>&1)
EC=$?
set -e
if [ $EC -ne 0 ] || echo "$RESP" | grep -qi "error\|fail\|invalid\|warning"; then
    : # pass — either nonzero exit or error in output
else
    echo "FAIL: validate bad Swift file did not report error (exit=$EC)"
    ERRORS=$((ERRORS + 1))
fi

# Test 3: Valid Swift file
cat > /tmp/senkani-test-good-$$.swift << 'SWIFT'
import Foundation
func hello() -> String {
    return "Hello, world!"
}
SWIFT

set +e
RESP=$($BIN validate /tmp/senkani-test-good-$$.swift 2>&1)
EC=$?
set -e
if [ $EC -eq 0 ] || echo "$RESP" | grep -qi "pass\|valid\|ok\|success\|clean"; then
    : # pass
else
    echo "FAIL: validate good Swift file reported error (exit=$EC)"
    ERRORS=$((ERRORS + 1))
fi

# Test 4: Invalid JSON
echo '{"broken": }' > /tmp/senkani-test-bad-$$.json

set +e
RESP=$($BIN validate /tmp/senkani-test-bad-$$.json 2>&1)
EC=$?
set -e
if [ $EC -ne 0 ] || echo "$RESP" | grep -qi "error\|fail\|invalid"; then
    : # pass
else
    echo "FAIL: validate bad JSON did not report error (exit=$EC)"
    ERRORS=$((ERRORS + 1))
fi

# Test 5: Valid JSON
echo '{"valid": true, "name": "test"}' > /tmp/senkani-test-good-$$.json

set +e
RESP=$($BIN validate /tmp/senkani-test-good-$$.json 2>&1)
EC=$?
set -e
if [ $EC -eq 0 ] || echo "$RESP" | grep -qi "pass\|valid\|ok\|success\|clean"; then
    : # pass
else
    echo "FAIL: validate good JSON reported error (exit=$EC)"
    ERRORS=$((ERRORS + 1))
fi

# Test 6: Non-existent file
set +e
RESP=$($BIN validate /tmp/senkani-nonexistent-$$.swift 2>&1)
EC=$?
set -e
if [ $EC -ne 0 ] || echo "$RESP" | grep -qi "error\|not found\|no such"; then
    : # pass
else
    echo "FAIL: validate non-existent file did not error (exit=$EC)"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== test-05-validators: $ERRORS error(s) ==="
[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS validator test(s) failed"; exit 1; }
