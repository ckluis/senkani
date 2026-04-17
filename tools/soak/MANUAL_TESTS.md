# Manual test queue

Items that need the operator's physical machine and/or a real LLM
client. Unit tests can't cover these. Tracked here so they don't fall
off the edge while autonomous work continues.

Updated 2026-04-17.

---

## Untriaged — needs a first run

### `senkani stats --security` live
After a real session with injection detections / SSRF blocks /
retention prunes, confirm:
- The dashboard shows non-zero counters for at least one category.
- Gelman rate annotation appears inline: `count/total (pct%)`.
- `--verbose` shows per-project rows.
- **Privacy gate:** no `/Users/<your-username>` string appears in
  the verbose output — it must be collapsed to `~` (current user)
  or `/Users/***` (foreign user).

### `senkani export --redact` round-trip
- `senkani export --output /tmp/exp.jsonl --redact`
- Every `row.project_root` column is either `~/...` or
  `/Users/***/...`.
- `row.command` and `row.output_preview` have no raw `/Users/<name>`
  paths.
- Piped form: `senkani export --output - | jq '.'` works.

### 12-scenario soak (S1–S12)
Full playbook lives in `~/.claude/plans/soak-after-wave-3.md`.
Journal template at `~/.claude/soak/TEMPLATE.md`. Scenarios:
S1 SSRF, S2 injection FP rate, S3 deprecation shim e2e,
S4 migration baselining, S5 retention pruning, S6 socket auth,
S7 parent-death, S8 instructions payload, S9 structured logs,
S10 crash-consistency, S11 secret redaction, S12 senkani_version.
Exit: 12/12 green, FP rate < 5% over N ≥ 20 injection triggers.

### `senkani uninstall` walkthrough
`spec/cleanup.md #15`. 7 artifact categories + `--yes` + `--keep-data`.
Verify everything the command claims to remove actually goes.

### `senkani wipe` walkthrough
`tools/soak/findings/cavoukian-privacy-pass-2026-04-16.md` C4. Dry-run
then `--yes`. Confirm:
- Session DB + WAL + SHM files deleted.
- Any `.schema.lock` / `.migrating` sidecars gone.
- `~/.senkani/.token` deleted (if `--include-config` also the
  whole `~/.senkani` dir).

### SenkaniApp GUI
Live pane widgets, ⌘K command palette, sparkline overlays, theme
picker, notification rings. Unit tests cover controllers; UI needs
eyeballs.

### `SENKANI_LOG_JSON=1` shape in a real session
Pipe stderr into `jq`. Every line must parse. Fields present:
`ts`, `event`, plus event-specific keys. No `/Users/<name>` paths
in text columns (C2/C5 sink redaction).

### `senkani_version` from a real MCP client
Surface it in the client's tool picker, round-trip the JSON, confirm
`tool_schemas_version` matches a fresh `gh` checkout's registry.

### Multi-process migration race
Only meaningful with two separately-installed processes (MCP server
+ GUI app both touching the DB). In-process testing is blocked by
BSD flock's per-process semantics (see
`sequentialRunnersAreIdempotent`).

---

## Closed via manual confirmation

*(empty — nothing confirmed yet; add rows with a commit hash + date
as items are verified)*

## Covered by automated smoke tests (no manual verification needed)

- `senkani <subcommand> --help` for all 20 subcommands — covered
  by `CLISmokeTests` (bc7fca1 → current). No need to type each
  `--help` by hand to check for arg-parser regressions.

---

## Won't verify

*(empty — items retired as no-longer-relevant)*
