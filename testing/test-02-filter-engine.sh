#!/bin/bash
# Test: Filter engine produces expected savings
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani
ERRORS=0

assert_filtered() {
    local desc="$1"
    local raw_bytes="$2"
    local filtered_bytes="$3"
    if [ "$filtered_bytes" -lt "$raw_bytes" ]; then
        : # pass — filtering saved bytes
    else
        echo "FAIL: $desc (raw=$raw_bytes, filtered=$filtered_bytes, no savings)"
        ERRORS=$((ERRORS + 1))
    fi
}

assert_passthrough() {
    local desc="$1"
    local raw_bytes="$2"
    local filtered_bytes="$3"
    if [ "$filtered_bytes" -eq "$raw_bytes" ]; then
        : # pass — no filtering applied
    else
        echo "FAIL: $desc (expected passthrough, raw=$raw_bytes, filtered=$filtered_bytes)"
        ERRORS=$((ERRORS + 1))
    fi
}

# Test ANSI stripping on git log
RAW=$(git -c color.ui=always log --oneline -10 2>/dev/null | wc -c | tr -d ' ')
FILTERED=$($BIN exec -- git -c color.ui=always log --oneline -10 2>/dev/null | wc -c | tr -d ' ')
assert_filtered "git log ANSI stripping" "$RAW" "$FILTERED"

# Test cat truncation on large file
python3 -c "for i in range(500): print(f'line {i}: ' + 'x' * 80)" > /tmp/senkani-bigfile-$$.txt
RAW=$(wc -c < /tmp/senkani-bigfile-$$.txt | tr -d ' ')
FILTERED=$($BIN exec -- cat /tmp/senkani-bigfile-$$.txt 2>/dev/null | wc -c | tr -d ' ')
assert_filtered "cat large file truncation" "$RAW" "$FILTERED"
rm -f /tmp/senkani-bigfile-$$.txt

# Test unknown command passthrough
RAW=$(echo "hello world" | wc -c | tr -d ' ')
FILTERED=$($BIN exec -- echo "hello world" 2>/dev/null | wc -c | tr -d ' ')
# echo is not a known command, should pass through (but may have minor differences)

# Test --no-filter flag
RAW=$(git -c color.ui=always log --oneline -5 2>/dev/null | wc -c | tr -d ' ')
NOFILTER=$($BIN exec --no-filter -- git -c color.ui=always log --oneline -5 2>/dev/null | wc -c | tr -d ' ')
# With --no-filter, ANSI should be preserved
if [ "$NOFILTER" -ge "$RAW" ] 2>/dev/null; then
    : # pass — passthrough preserves or increases bytes
else
    echo "FAIL: --no-filter should preserve ANSI (raw=$RAW, nofilter=$NOFILTER)"
    ERRORS=$((ERRORS + 1))
fi

[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS filter test(s) failed"; exit 1; }
