#!/bin/bash
# S9 — parse a captured structured-log stream. Every line must be
# valid JSON, every record must have `ts` and `event`.
# Usage:
#   SENKANI_LOG_JSON=1 ...senkani run... 2> /tmp/senkani.log
#   tools/soak/parse-logs.sh /tmp/senkani.log

LOG="${1:-/tmp/senkani.log}"
if [ ! -f "$LOG" ]; then
  echo "FAIL: no log file at $LOG"
  exit 1
fi

total=0
parsed=0
failed=0
missing_ts=0
missing_event=0

while IFS= read -r line; do
  [ -z "$line" ] && continue
  total=$((total+1))
  python3 - "$line" <<'PY' && parsed=$((parsed+1)) || failed=$((failed+1))
import sys, json
line = sys.argv[1]
try:
    obj = json.loads(line)
except Exception:
    sys.exit(1)
if "ts" not in obj or "event" not in obj:
    sys.exit(2)
PY
done < "$LOG"

echo "total: $total"
echo "parsed: $parsed"
echo "failed: $failed"
if [ "$total" -eq "$parsed" ] && [ "$failed" -eq 0 ]; then
  echo "PASS"
else
  echo "FAIL: some lines did not parse or were missing ts/event"
  echo ""
  echo "--- first 5 failing lines ---"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "$line" | python3 -c 'import sys, json; obj=json.loads(sys.stdin.read()); assert "ts" in obj and "event" in obj' >/dev/null 2>&1 || echo "BAD: $line"
  done < "$LOG" | head -5
fi
