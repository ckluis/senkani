# Cavoukian privacy pass — 2026-04-16

Adversarial read of what the Senkani session DB + sidecar files store
about the user, through Cavoukian's "privacy by design" lens. What
can the user access? What can they delete? What's leaking unredacted
into long-lived storage?

## Scope
- `~/Library/Application Support/Senkani/senkani.db` — primary session DB
- `~/.senkani/.token` — socket-auth token (F2/F6)
- Structured log stream on stderr (`SENKANI_LOG_JSON=1`)
- `senkani.db-wal` / `-shm` — SQLite WAL sidecars
- Migration lockfiles (`.migrating`, `.schema.lock`)

## Inventory — what's stored

| Table | Sensitive fields | Retention |
|-------|------------------|-----------|
| `sessions` | `project_root` (full path, includes /Users/<username>) | unbounded |
| `commands` | **`command` (raw shell text)**, `output_preview` (500 chars, filter-applied) | unbounded |
| `token_events` | `project_root`, `command`, `pane_id`, `session_id` | **90 d** (pruned hourly) |
| `sandboxed_results` | `full_output` (filter-applied) | **24 h** (pruned hourly) |
| `validation_results` | `raw_output`, `advisory`, `file_path` | **24 h** (pruned hourly) |
| `claude_session_cursors` | `path` (Claude Code JSONL file paths) | unbounded |
| `schema_migrations` | version, description, applied_at | unbounded |

## Findings

### C1 — P2: `commands.command` stores shell text unredacted (CLOSED)

**Evidence:** `SessionDatabase.recordCommand` (line 309 before this
commit) took a `command: String?` and bound it directly via
`sqlite3_bind_text` with no filtering. `output_preview` was filtered
upstream by FilterPipeline (applied to the POST-filter output), but
the raw command string — whatever the user or LLM typed into
`senkani_exec` — landed in the DB as-is.

**Exploit shape:** a user (or prompt-injected LLM) running
```
senkani_exec command:"curl -H 'Authorization: Bearer sk-ant-…' https://…"
```
left the literal API key in `commands.command` for the unbounded
lifetime of that row. Since `commands` has no retention, this was
**forever**. Backed up in any DB copy, visible to any same-UID
process that read the DB, queryable via the `commands_fts` FTS5
table, included in any `senkani export` dump.

**Fix (this commit):** redact the command string through
`SecretDetector.scan` before the `sqlite3_bind_text` call. The
existing short-circuit in SecretDetector (F1-8 from the earlier
round) means the benign-case cost is one cheap firstMatch probe per
pattern. Output preview was already filter-applied; command now
matches.

**Test:** `SessionDatabaseTests` already covers `recordCommand`;
extended with a case asserting that `sk-ant-…` in the command is
redacted to `[REDACTED:ANTHROPIC_API_KEY]` in the DB.

### C4 — P2: No user-facing data wipe (CLOSED)

**Evidence:** there is no command to delete user session data.
Users who wanted to erase their footprint had to know the
Application Support path and manually `rm` the DB file + its
-wal/-shm sidecars + the socket-auth token. Not a discoverable
affordance — contrary to "privacy by design" default-access.

**Fix (this commit):** new `Sources/CLI/WipeCommand.swift`. Usage:
```
senkani wipe           # dry run — lists what would be deleted
senkani wipe --yes     # actual deletion
senkani wipe --yes --include-config   # also deletes ~/.senkani/
```
Destructive actions (Jobs) require explicit `--yes`. Running without
`--yes` prints the victim list and exits non-destructively. Removes:
- senkani.db + -wal + -shm
- schema.lock / .migrating sidecars
- ~/.senkani/.token (socket-auth token)
- Optionally: entire ~/.senkani directory (skills, pane state)

### C2 — P3: `project_root` contains home path + username (OPEN)

`sessions.project_root` stores paths like
`/Users/<username>/Projects/senkani`. Usable as an index key but
echoes the username into any log or export. `ProjectSecurity.redactPath`
exists as a display helper but isn't used at storage time (can't be —
paths are correlation keys).

**Mitigation plan:** add a `--redact` flag to a future `senkani export`
that applies `ProjectSecurity.redactPath` to output.

### C3 — P2: No data-portability export (OPEN)

No `senkani export` command. User can't retrieve their own session
data except by querying the SQLite file directly.

**Mitigation plan:** ship `senkani export --output path.jsonl` that
emits sessions + commands + token_events as JSONL. Respect
`--redact` to apply path redaction. Not shipped this round.

### C5 — P3: Log stream may carry sensitive fields (OPEN)

`SENKANI_LOG_JSON=1` events include `session_id`, `tool`, occasionally
`command` fragments, `host` from SSRF blocks. Session ID is a UUID
(safe). Tool name is safe. Command fragments aren't filter-applied in
log payloads the way `commands.command` now is.

**Mitigation plan:** audit every `Logger.log` call site for the
fields it passes; apply `SecretDetector.scan` where any `command`
or user-text field is emitted.

## Summary

| ID | Severity | Status | Closed in |
|---|----|----------|--------|
| C1 | Unredacted command text in DB | P2 | ✅ fixed this commit |
| C4 | No user-facing wipe | P2 | ✅ fixed this commit |
| C2 | project_root leaks username | P3 | open — needs --redact export flag |
| C3 | No data-portability export | P2 | open — `senkani export` planned |
| C5 | Log field redaction audit | P3 | open — next round |

C1 + C4 addressed this round. C2/C3/C5 tracked. Retention already
covers token_events (90d), sandboxed_results (24h), and
validation_results (24h) — the unbounded-retention table that matters
most (commands) is now covered at the redaction layer.
