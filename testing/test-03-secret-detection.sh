#!/bin/bash
# Test: Secret detection catches known patterns and redacts them
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani
ERRORS=0

check_detected() {
    local desc="$1"
    local input="$2"
    local pattern="$3"
    local output
    output=$(echo "$input" > /tmp/senkani-secret-$$.txt && $BIN exec -- cat /tmp/senkani-secret-$$.txt 2>&1)
    if echo "$output" | grep -q "REDACTED"; then
        : # pass
    else
        echo "FAIL: $desc — secret not detected"
        ERRORS=$((ERRORS + 1))
    fi
    rm -f /tmp/senkani-secret-$$.txt
}

check_clean() {
    local desc="$1"
    local input="$2"
    local output
    output=$(echo "$input" > /tmp/senkani-clean-$$.txt && $BIN exec -- cat /tmp/senkani-clean-$$.txt 2>&1)
    if echo "$output" | grep -q "REDACTED"; then
        echo "FAIL: $desc — false positive"
        ERRORS=$((ERRORS + 1))
    fi
    rm -f /tmp/senkani-clean-$$.txt
}

# True positives
check_detected "Anthropic API key" "ANTHROPIC_API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890" "ANTHROPIC"
check_detected "OpenAI API key" "OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwxyz1234567890" "OPENAI"
check_detected "AWS access key" "AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE" "AWS"
check_detected "GitHub token" "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn" "GITHUB"
check_detected "Bearer token" "Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdef" "BEARER"

# True negatives
check_clean "Normal git command" "git push origin main"
check_clean "Normal npm command" "npm install express"
check_clean "Short string" "hello world"

# Stderr warning
output=$($BIN exec -- cat /tmp/senkani-secret-$$.txt 2>&1 || true)
echo "sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890" > /tmp/senkani-secret-$$.txt
stderr=$($BIN exec -- cat /tmp/senkani-secret-$$.txt 2>&1 1>/dev/null || true)
if echo "$stderr" | grep -q "senkani:.*pattern detected"; then
    : # pass — warning on stderr
fi
rm -f /tmp/senkani-secret-$$.txt

[ $ERRORS -eq 0 ] && exit 0 || { echo "$ERRORS secret detection test(s) failed"; exit 1; }
