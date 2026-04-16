#!/bin/bash
# S5 — plant a 91-day-old token_events row; wait for the next
# retention.tick; verify it's gone.
set -e

DB="$HOME/Library/Application Support/Senkani/senkani.db"
if [ ! -f "$DB" ]; then
  echo "FAIL: DB not found at $DB. Run Senkani at least once first."
  exit 1
fi

sqlite3 "$DB" "INSERT INTO token_events(timestamp, session_id, source, cost_cents) VALUES (strftime('%s','now','-91 days')+0.0, 'soak-test', 'manual', 0);"

echo "Planted a soak-test row dated 91 days ago."
echo ""
echo "Wait for the next retention.tick (up to 1 hour), then run:"
echo "  sqlite3 \"$DB\" \"SELECT COUNT(*) FROM token_events WHERE session_id='soak-test';\""
echo "Expected: 0"
echo ""
echo "If SENKANI_LOG_JSON=1 was active, the tick is visible via:"
echo "  grep retention.tick /path/to/senkani.stderr"
