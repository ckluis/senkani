#!/bin/bash
# S4 — verify migration baselining stamped v1 without running ALTERs
# on an existing DB.
set -e

DB="$HOME/Library/Application Support/Senkani/senkani.db"

if [ ! -f "$DB" ]; then
  echo "FAIL: DB not found at $DB"
  exit 1
fi

echo "== PRAGMA user_version =="
uv=$(sqlite3 "$DB" "PRAGMA user_version;")
echo "user_version: $uv"

echo ""
echo "== schema_migrations rows =="
sqlite3 "$DB" "SELECT version, description, datetime(applied_at,'unixepoch') FROM schema_migrations;"

echo ""
rows=$(sqlite3 "$DB" "SELECT COUNT(*) FROM schema_migrations;")
echo "rowcount: $rows"
echo ""
if [ "$uv" = "1" ] && [ "$rows" = "1" ]; then
  echo "PASS: user_version=1, exactly one baseline row."
else
  echo "INVESTIGATE: expected user_version=1 + 1 row. See output above."
fi
