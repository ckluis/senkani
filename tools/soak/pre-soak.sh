#!/bin/bash
# Pre-soak sanity: verify the tree is in the state the plan assumes.
# Run from repo root.
set -e
cd "$(dirname "$0")/../.."

echo "== Git HEAD =="
git log --oneline -5

echo ""
echo "== Build (release) =="
swift build -c release 2>&1 | tail -3

echo ""
echo "== Tests =="
swift test 2>&1 | tail -1

echo ""
echo "== Migration state =="
DB="$HOME/Library/Application Support/Senkani/senkani.db"
if [ -f "$DB" ]; then
  sqlite3 "$DB" "PRAGMA user_version;"
  sqlite3 "$DB" "SELECT version, description, datetime(applied_at,'unixepoch') FROM schema_migrations;"
else
  echo "(fresh install — DB not yet created; will be created on first senkani-mcp run)"
fi

echo ""
echo "== Baseline signals =="
if pgrep senkani-mcp >/dev/null; then
  for pid in $(pgrep senkani-mcp); do
    rss=$(ps -o rss= -p "$pid" | tr -d ' ')
    fds=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ')
    echo "senkani-mcp pid=$pid rss_kb=$rss fds=$fds"
  done
else
  echo "(no senkani-mcp running)"
fi
[ -f "$DB" ] && du -h "$DB"

echo ""
echo "== Ready =="
echo "If everything above looks green, begin the soak. Fill"
echo "~/.claude/soak/$(date -I).md from ~/.claude/soak/TEMPLATE.md."
