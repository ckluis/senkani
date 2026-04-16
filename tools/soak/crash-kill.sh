#!/bin/bash
# S10 — crash-consistency: kill senkani-mcp mid-operation and verify
# that `sessions.command_count` per session_id still matches `commands`
# row count after restart.
set -e

pid=$(pgrep senkani-mcp | head -1)
if [ -z "$pid" ]; then
  echo "FAIL: no senkani-mcp process running"
  exit 1
fi

echo "Sending SIGKILL to senkani-mcp pid=$pid"
kill -9 "$pid"
echo "Killed."

echo ""
echo "After the daemon has been restarted (e.g. next pane open):"
DB="$HOME/Library/Application Support/Senkani/senkani.db"
echo '  sqlite3 "'$DB'" "SELECT session_id, command_count FROM sessions ORDER BY started_at DESC LIMIT 3;"'
echo '  sqlite3 "'$DB'" "SELECT session_id, COUNT(*) FROM commands GROUP BY session_id ORDER BY session_id DESC LIMIT 3;"'
echo ""
echo "Expected: same session_id → same count."
