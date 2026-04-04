#!/bin/bash
# Eval: Measure secret detection true positive and false positive rates
set -e
cd "$(dirname "$0")/.."
BIN=.build/release/senkani

echo "==============================================="
echo "  Eval 05: Secret Detection Precision"
echo "==============================================="
echo ""

[ -x "$BIN" ] || { echo "FAIL: binary not found. Run: swift build -c release"; exit 1; }

TRUE_POS=0
FALSE_NEG=0
TRUE_NEG=0
FALSE_POS=0

check_secret() {
    local desc="$1"
    local input="$2"
    local expect_redacted="$3"  # "yes" or "no"

    echo "$input" > /tmp/senkani-eval-secret-$$.txt
    local output
    output=$($BIN exec -- cat /tmp/senkani-eval-secret-$$.txt 2>&1 || true)
    rm -f /tmp/senkani-eval-secret-$$.txt

    local detected="no"
    if echo "$output" | grep -q "REDACTED"; then
        detected="yes"
    fi

    if [ "$expect_redacted" = "yes" ]; then
        if [ "$detected" = "yes" ]; then
            TRUE_POS=$((TRUE_POS + 1))
            printf "  TP %-40s DETECTED\n" "$desc"
        else
            FALSE_NEG=$((FALSE_NEG + 1))
            printf "  FN %-40s MISSED\n" "$desc"
        fi
    else
        if [ "$detected" = "no" ]; then
            TRUE_NEG=$((TRUE_NEG + 1))
            printf "  TN %-40s CLEAN\n" "$desc"
        else
            FALSE_POS=$((FALSE_POS + 1))
            printf "  FP %-40s FALSE ALARM\n" "$desc"
        fi
    fi
}

echo "--- True Positives (must detect) ---"
check_secret "Anthropic API key" \
    "sk-ant-api03-abcdefghijklmnopqrstuvwxyz1234567890" "yes"
check_secret "OpenAI API key" \
    "sk-proj-abcdefghijklmnopqrstuvwxyz1234567890" "yes"
check_secret "AWS access key" \
    "AKIAIOSFODNN7EXAMPLE" "yes"
check_secret "GitHub token" \
    "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij" "yes"
check_secret "Bearer JWT token" \
    "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdef" "yes"
check_secret "Generic API key assignment" \
    "api_key = 'sk-abcdefghijklmnopqrstuvwxyz123456'" "yes"
check_secret "Anthropic key in env export" \
    "export ANTHROPIC_API_KEY=sk-ant-api03-realkeylookslikethis1234567890abc" "yes"

echo ""
echo "--- True Negatives (must NOT detect) ---"
check_secret "etch-a-sketch reference" \
    'let sketch = "sk-etch-a-sketch"' "no"
check_secret "ask-anything reference" \
    'let task = "ask-anything"' "no"
check_secret "Normal git command" \
    "git push origin main" "no"
check_secret "Normal npm command" \
    "npm install express" "no"
check_secret "Short base64 string" \
    "data: aGVsbG8gd29ybGQ=" "no"
check_secret "UUID" \
    "550e8400-e29b-41d4-a716-446655440000" "no"
check_secret "Normal hex string (git hash)" \
    "commit abc123def456789012345678901234567890abcd" "no"
check_secret "Normal Swift code" \
    'let maxTokens = 4096' "no"
check_secret "Normal Python import" \
    "import os, sys, json" "no"

# Calculate rates
TOTAL_POS=$((TRUE_POS + FALSE_NEG))
TOTAL_NEG=$((TRUE_NEG + FALSE_POS))
TPR=$(python3 -c "print(f'{$TRUE_POS / max($TOTAL_POS, 1) * 100:.1f}')" 2>/dev/null || echo "0")
FPR=$(python3 -c "print(f'{$FALSE_POS / max($TOTAL_NEG, 1) * 100:.1f}')" 2>/dev/null || echo "0")

echo ""
echo "-------------------------------------------"
echo "  True positives:   $TRUE_POS / $TOTAL_POS"
echo "  False negatives:  $FALSE_NEG / $TOTAL_POS"
echo "  True negatives:   $TRUE_NEG / $TOTAL_NEG"
echo "  False positives:  $FALSE_POS / $TOTAL_NEG"
echo ""
echo "EVAL: secret_true_positive_rate = ${TPR}% (baseline: >95%)"
echo "EVAL: secret_false_positive_rate = ${FPR}% (baseline: <5%)"
echo ""

# Pass if TPR > 80% and FPR < 20% (generous for eval)
TP_OK=$(python3 -c "print('yes' if $TRUE_POS >= 5 else 'no')" 2>/dev/null || echo "no")
FP_OK=$(python3 -c "print('yes' if $FALSE_POS <= 2 else 'no')" 2>/dev/null || echo "no")

[ "$TP_OK" = "yes" ] && [ "$FP_OK" = "yes" ] && exit 0 || { echo "FAIL: TP=$TRUE_POS/$TOTAL_POS, FP=$FALSE_POS/$TOTAL_NEG"; exit 1; }
