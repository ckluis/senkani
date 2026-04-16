# tools/soak — Wave-3 soak infrastructure

Helper scripts + scenario notes for the field-observation pass that
precedes the next Luminary audit round.

## Flow

1. `tools/soak/pre-soak.sh` — one-shot sanity: build, test, git HEAD,
   migration state, baseline signals.
2. Copy `~/.claude/soak/TEMPLATE.md` → `~/.claude/soak/$(date -I).md`.
3. Work a real session. Call the scenario helpers as you go (scripts
   are idempotent and non-destructive except where the plan says so).
4. `tools/soak/signal-snapshot.sh` at t0, t+4h, t+24h.
5. Exit when the 12-scenario checklist is complete and passive
   signals are flat.

## Scripts

| Script | Scenario | Purpose |
|--------|----------|---------|
| `pre-soak.sh` | pre | Sanity baseline |
| `signal-snapshot.sh` | passive | RSS / FDs / DB size |
| `check-migrations.sh` | S4 | schema_migrations truth |
| `plant-stale-row.sh` | S5 | Force retention prune |
| `socket-auth-probe.sh` | S6 | Handshake verification |
| `parse-logs.sh` | S9 | JSON-mode log validation |
| `crash-kill.sh` | S10 | Crash-consistency setup |
| `secret-fixture.sh` | S11 | Redaction fixture |

## Documents

| File | Scenario |
|------|----------|
| `ssrf-probes.md` | S1 |
| `version-expected.md` | S12 |

Scenarios S2, S3, S7, S8 are observed during normal use and captured
in the journal — no script required.

## Plan & exit criteria

See `~/.claude/plans/soak-after-wave-3.md`.
