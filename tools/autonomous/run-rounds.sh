#!/usr/bin/env bash
#
# run-rounds.sh — unattended driver for the senkani autonomous loop.
#
# Each iteration invokes `claude -p "/senkani-autonomous"` in a FRESH
# context (`claude -p` creates a new session per call). The script
# sleeps between rounds and exits cleanly when the backlog empties.
#
# Usage:
#   tools/autonomous/run-rounds.sh                       # default 10min gap, forever
#   tools/autonomous/run-rounds.sh --gap 1800            # 30min between rounds
#   tools/autonomous/run-rounds.sh --max 5               # exit after 5 rounds
#   tools/autonomous/run-rounds.sh --dry-run             # log what would run, don't invoke claude
#
# Stops when:
#   1. Backlog has no `pending` items with satisfied blockers
#   2. `--max N` iterations completed
#   3. User sends SIGTERM/SIGINT
#   4. `in_flight` is non-null at round start (operator has to clear
#      it — the skill refuses to start over a stuck lock)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BACKLOG="$REPO_ROOT/spec/autonomous-backlog.yaml"

GAP_SECONDS="${GAP_SECONDS:-600}"
MAX_ROUNDS=""
DRY_RUN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --gap)     GAP_SECONDS="$2";  shift 2 ;;
        --max)     MAX_ROUNDS="$2";   shift 2 ;;
        --dry-run) DRY_RUN=1;         shift   ;;
        -h|--help)
            sed -n '1,30p' "$0"; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -f "$BACKLOG" ]]; then
    echo "backlog not found: $BACKLOG" >&2
    exit 1
fi

round=0
while : ; do
    round=$((round + 1))

    if [[ -n "$MAX_ROUNDS" && "$round" -gt "$MAX_ROUNDS" ]]; then
        echo "[$(date -u +%FT%TZ)] --max reached, exiting"
        exit 0
    fi

    # Backlog quick-sanity: any pending items left?
    if ! grep -q "^  - id:.*$" "$BACKLOG"; then
        echo "[$(date -u +%FT%TZ)] backlog appears empty, exiting"
        exit 0
    fi
    if ! grep -q "status: pending" "$BACKLOG"; then
        echo "[$(date -u +%FT%TZ)] no items with status: pending, exiting"
        exit 0
    fi
    if grep -q '^in_flight: "[^"]' "$BACKLOG"; then
        stuck="$(grep -E '^in_flight:' "$BACKLOG" | head -1)"
        echo "[$(date -u +%FT%TZ)] in-flight lock detected ($stuck). A prior round did not clean up." >&2
        echo "Manually reset spec/autonomous-backlog.yaml: set in_flight: null and" >&2
        echo "  mark the stuck item status: skipped with a note. Then re-run." >&2
        exit 3
    fi

    echo "==============================================================="
    echo "[$(date -u +%FT%TZ)] Round $round — invoking /senkani-autonomous"
    echo "==============================================================="

    if [[ -n "$DRY_RUN" ]]; then
        echo "(dry run) would run: claude -p '/senkani-autonomous'"
    else
        # Fresh context per invocation — claude -p creates a new session.
        # Use --output-format text so stdout is human-readable; machine-
        # readable consumers should prefer --output-format json and pipe
        # through jq for structured round summaries.
        claude -p "/senkani-autonomous" --output-format text || {
            rc=$?
            echo "[$(date -u +%FT%TZ)] round exited with code $rc" >&2
            # Don't try to auto-recover — the backlog-in_flight check
            # at the top of the next iteration will surface a crashed
            # round.
            exit $rc
        }
    fi

    echo "[$(date -u +%FT%TZ)] sleeping ${GAP_SECONDS}s before next round..."
    sleep "$GAP_SECONDS"
done
