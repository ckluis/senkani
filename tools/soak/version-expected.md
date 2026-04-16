# S12 — `senkani_version` expected output

Call from Claude Code:

```
senkani_version
```

Expected shape:

```json
{
  "server_version": "0.2.0",
  "tool_schemas_version": 1,
  "schema_db_version": 1,
  "tools": ["deps", "embed", "exec", "explore", "fetch", "knowledge",
            "outline", "pane", "parse", "read", "search", "session",
            "validate", "version", "vision", "watch", "web"]
}
```

Invariants (Lauret + Evans):
- 17 tools in the list, alphabetized.
- `server_version` matches `VersionTool.serverVersion` constant.
- `tool_schemas_version` is `1` this release; bumps to `2` when
  `detail` is removed from knowledge/validate.
- `schema_db_version` matches `PRAGMA user_version` on
  `senkani.db`; expected `1` after Wave-1 migration baselined.
