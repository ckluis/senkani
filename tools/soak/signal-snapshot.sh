#!/bin/bash
# Snapshot passive signals (RSS / FDs / DB size) for the journal.
# Append output to ~/.claude/soak/YYYY-MM-DD.md under Passive signals.

echo "time: $(date -Iseconds)"
DB="$HOME/Library/Application Support/Senkani/senkani.db"

if pgrep senkani-mcp >/dev/null; then
  for pid in $(pgrep senkani-mcp); do
    rss=$(ps -o rss= -p "$pid" | tr -d ' ')
    fds=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ')
    printf "senkani-mcp pid=%s rss_kb=%s fds=%s\n" "$pid" "$rss" "$fds"
  done
else
  echo "senkani-mcp: not running"
fi

if [ -f "$DB" ]; then
  size=$(du -k "$DB" | cut -f1)
  echo "db_size_kb: $size"
fi
