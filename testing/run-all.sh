#!/bin/bash
# Senkani — Run all acceptance tests
# Usage: ./testing/run-all.sh [--evals]

set -e
cd "$(dirname "$0")/.."

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

run_test() {
    local script="$1"
    local name=$(basename "$script" .sh)
    printf "%-40s " "$name"

    if [ ! -x "$script" ]; then
        printf "${YELLOW}SKIP${NC} (not executable)\n"
        SKIP=$((SKIP + 1))
        return
    fi

    if output=$("$script" 2>&1); then
        printf "${GREEN}PASS${NC}\n"
        PASS=$((PASS + 1))
    else
        printf "${RED}FAIL${NC}\n"
        echo "$output" | head -5 | sed 's/^/  /'
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  Senkani Acceptance Tests"
echo "═══════════════════════════════════════════"
echo ""

# Build first
echo "Building..."
swift build -c release 2>&1 | tail -1
echo ""

# Unit tests
echo "Swift unit tests..."
swift test 2>&1 | tail -1
echo ""

# Acceptance tests
echo "Acceptance tests:"
echo "─────────────────────────────────────────"

for script in testing/test-*.sh; do
    [ -f "$script" ] && run_test "$script"
done

echo ""
echo "─────────────────────────────────────────"
echo "Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"

# Run evals if --evals flag
if [ "$1" = "--evals" ]; then
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Quality Evals"
    echo "═══════════════════════════════════════════"
    echo ""

    for script in testing/eval-*.sh; do
        [ -f "$script" ] && run_test "$script"
    done

    echo ""
    echo "─────────────────────────────────────────"
    echo "Eval Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}"
fi

[ $FAIL -eq 0 ] && exit 0 || exit 1
