# Senkani — Manual test queue

Live things that unit tests and CI can't validate. Exercise when you're
back at your machine and can attach Senkani to a real Claude Code (or
Cursor / Codex) session. Tick items off with a date line.

Older queue items are also tracked in `spec/roadmap.md` "Manual test queue
(requires real sessions / user's physical machine)" — this file is the
wave-by-wave operator diary; the roadmap is the long-lived spec.

---

## 2026-06-11 — Settings → Notifications matrix pane shipped — visual render walk pending

Item `t6-settings-notifications-matrix-ui-2026-05-21` partial-shipped its
code slice on `carves/drain-2026-06-09`: the sidebar **Notifications**
tool view (per-sink × per-event checkbox matrix over
`~/.senkani/notifications.json`, deterministic writer, live router
reload on every flip, test-fire buttons). All matrix/reload semantics
are CI-tested headlessly (`NotificationsMatrixSettingsTests`, 16 tests);
what CI cannot prove is the RENDER + interaction.

**Walk (exec mode: cowork-driven with operator at the GUI; ~10 min):**

1. Launch SenkaniApp (Xcode-built or `swift run SenkaniApp`); sidebar
   TOOLS → click **Notifications** (bell.badge row, under Trust Flags).
2. Verify the matrix renders: rows "Stdout (JSON log line)" +
   "macOS banner", columns Done / Failure / Schedule end, all ticked on
   a fresh machine (no config file = default-on).
3. Untick (macOS banner, Done) → confirm `~/.senkani/notifications.json`
   appears with `macos_local: ["notify_failure","schedule_end"]`.
4. Click **Fire done** → no banner; stdout pane/log shows the JSON line.
   Click **Fire failure** → banner appears (TCC-authorized build).
5. Re-tick the cell → **Fire done** → banner appears. No app restart at
   any point.
6. Screenshot the pane for `docs/guides/install.html` (acceptance #5's
   screenshot is still owed; the prose shipped 2026-06-11).
7. Walk evidence + ticks → `## Build note 2026-06-11` in the item file
   (`spec/autonomous/backlog/t6-settings-notifications-matrix-ui-2026-05-21.md`).

## 2026-06-07 — T.4c-1 Phase A vault seams landed — real-Keychain walk now runnable

`phase-t4c-1-vault-phase-a-seams` shipped the CI-testable "Phase A" wiring
the operator-gated `phase-t4c-credential-vault-real-keychain` walk asserts
in its `## Pre-conditions` table — all proven against
`InMemoryKeychainStore`, so NO production behavior flips in CI:

- `senkani vault list` → `(scope, key, <N> bytes)` rows (never the value).
- `senkani doctor --vault-status` / `--latency-runs N` / `--latency-key K`
  → round-trip OK + per-scope key count + p95/p99 (value-free).
- `HookRouter.installProductionCredentialVaultBridge()` wired at CLI,
  MCP-server, and `SenkaniApp` init — the gateway lookup now bridges into
  `CredentialVault.shared` (still an empty `InMemoryKeychainStore` in prod;
  fail-CLOSED preserved — missing keys still DENY).
- `tools/soak/t4c-corpus-runner.sh` — spawns `senkani-mcp` over stdio,
  fires 20 `tools/call`, captures `corpus.jsonl` (no keychain dep).

**Operator-gated REMAINDER (run this on a real Mac with an unlocked login
Keychain):** the parent walk's Steps 1, 4-real, 5-real, 6, 7, 9 plus the
`CredentialVault.shared = MacOSKeychainStore()` swap. Specifically still
NEEDS the operator / Cowork:

1. Flip `CredentialVault.shared` to `MacOSKeychainStore()` (the swap that
   needs this very proof) — or run the walk against a build that does.
2. `senkani vault add --key "$SENTINEL_KEY"` (gui-human: first-run macOS
   Keychain "Always Allow" prompt; getpass needs a real tty).
3. `senkani doctor --vault-status --latency-runs 100 --latency-key
   "$SENTINEL_KEY"` → assert p95 < 5 ms on the REAL Keychain.
4. `tools/soak/t4c-corpus-runner.sh` against a tool whose
   `credentialGateway.enabled=true` references `$SENTINEL_KEY` → 20 lines,
   zero `.error`.
5. Scan all four chained tables + raw `senkani.db` bytes + the captured
   plain-text artifacts for `$SENTINEL_VALUE` → ZERO matches (the
   sentinel-leak proof InMemoryKeychainStore cannot give).
6. Teardown via `senkani vault remove` + Cowork screenshot of the
   value-free `vault list` / `doctor --vault-status` output.

See `spec/autonomous/backlog/phase-t4c-credential-vault-real-keychain.md`
for the full step table. (`phase-t4c-1-vault-phase-a-seams-2026-06-07`)

---

## 2026-05-31 — V.13e-4b real-completion OpenAI conformance — model-present validation

`phase-v13e-4b-real-completion-conformance` shipped 4 REAL-model conformance
cases (`Tests/SenkaniTests/OpenAIRealCompletionConformanceTests.swift`) for the
OpenAI-compatible endpoint — chat non-stream, chat stream/SSE, embeddings,
tool-use — that register the real MLX adapters in-process, gate on model
presence, and assert range/shape content sanity. In CI (model-absent) all four
SKIP green; the live-model assertions only EXECUTE on a machine with the models
downloaded. Run this walk when back at a Mac with a Gemma 4 tier + `minilm-l6`
installed to prove the cases actually run (not skip) and pass.

- **Item:** `phase-v13e-4b-real-completion-conformance` (real-completion OpenAI conformance, all four surfaces).
- **Exec mode:** **either (shell)** (Cowork OR operator host Terminal — both can build the repo and run `swift test`; no `~/.claude` edits needed).
- **Time estimate:** ~15–40 min (model download dominates: ~2 min build, the rest is download + first-load).
- **Steps:**
    1. Download a Gemma 4 tier (e.g. `gemma4-e2b`) AND `minilm-l6` via the **SenkaniApp Models pane** (CLI `models pull` is NOT wired for the VLM tiers — see `ModelsCommand.swift:175`; the embedding model can come via either path, but the Models pane is the reliable route for both).
    2. Confirm readiness: the Gemma tier shows `.downloaded`/`.verified` and `minilm-l6` shows `.downloaded`/`.verified` in the Models pane (this is what `ModelManager.isReady` reads).
    3. Run `swift test --filter OpenAIRealCompletionConformance`.
    4. Confirm the 4 cases **EXECUTE rather than skip** — each should take meaningfully longer than the ~0.006s model-absent skip (real MLX load + inference), and the run transcript should show real content flowing (chat non-stream non-empty + valid `finish_reason`; SSE deltas accumulate; embedding vector is 384-dim with variance; tool-use either elicits a well-formed `tool_calls` OR logs a `[v13e-4b-finding]` decline, both of which PASS).
    5. Grep stderr for `[v13e-4b-finding]` — any finding (empty content, degenerate embedding, tool-call decline) is captured as round evidence, not a failure.
- **What it proves:** the real on-device Gemma 4 + MiniLM-L6 inference satisfies the range/shape content-sanity assertions through the production OpenAI serve seams (sync bridge + `renderStreamingEvents` SSE + the embedding adapter), end-to-end, on a model-present machine.
- **What lands as evidence:** the `swift test --filter OpenAIRealCompletionConformance` transcript (per-case durations proving execution-not-skip) + any `[v13e-4b-finding]` stderr lines.

## 2026-05-31 — Schedules pane a-2 (edit-in-place / drag-reorder / validation tooltips real-machine walk)

`schedule-senkaniapp-pane-2026-05-21-a-2` shipped edit-in-place, drag-reorder, and
inline validation tooltips on the Schedules pane. CI covers only the SwiftUI sub-view
declarations (`#filePath` source-scan guards); it cannot prove the live launchd behavior
or the SwiftUI body composition. Run this walk when back at a Mac with launchd in your
control. **This item is `groomable: true`** — a groom round will write the full
Cowork-runnable plan; this is the pointer entry.

- **Item:** [`spec/autonomous/completed/2026/2026-05-31-schedule-senkaniapp-pane-2026-05-21-a-2.md`](../../spec/autonomous/completed/2026/2026-05-31-schedule-senkaniapp-pane-2026-05-21-a-2.md)
- **Exec mode:** **either** (Cowork OR operator host — needs the real SenkaniApp running + `launchctl` visibility).
- **Time estimate:** ~12 min operator-supervised.
- **What it proves:** prose round-trip (compose → compiled cron → next-fires → create); amplification banner turns red on `.amplification`; **edit-in-place** of an existing schedule (compose surface reopens prefilled); **drag-reorder persistence across relaunch**; toggle/disable; delete.
- **⚠ Two filed P1 launchd defects to verify here (NOT yet fixed):**
  `schedule-edit-in-place-launchd-rearm-2026-05-31` — edit a cron/prose schedule's cadence, then confirm whether the **live launchd job actually re-fires on the new cadence** (current code does not unload-then-reload, so it likely keeps the OLD cadence until logout/login). And `schedule-edit-mode-switch-stale-plist-2026-05-31` — edit a cron/prose schedule down to **counter** mode and confirm the old cron plist is gone from `~/Library/LaunchAgents/` (current code leaves it → ghost double-fire). Capture observed behavior to drive those fixes.

## 2026-05-28 — V.13c real embedding-inference backend (registered-handler real-machine pass)

`phase-v13c-real-embedding-inference-backend-2026-05-27` shipped the
`EmbeddingEngine` protocol seam + MCP-side MLX registration + sync
bridge + readiness gate; CI covers the seam shape (6 new tests +
the unchanged 8 v13c tests) but cannot verify real on-device MiniLM
inference fidelity. Run this walk when back at a Mac with the
embedding model state in your control.

- **Item:** [`spec/autonomous/completed/2026/2026-05-28-phase-v13c-real-embedding-inference-backend-2026-05-27.md`](../../spec/autonomous/completed/2026/2026-05-28-phase-v13c-real-embedding-inference-backend-2026-05-27.md) — full surface contract + scope decisions live in the item.
- **Exec mode:** **either** (Cowork OR operator host Terminal — both have `curl` and can invoke `senkani serve`; no `~/.claude` edits needed).
- **Time estimate:** ~12 min operator-supervised — ~2 min repo build, ~2 min start serve, ~2 min curl round-trip with model downloaded, ~3 min flip ModelManager to a partial state and verify the 503 path, ~3 min teardown.
- **What it proves:**
    1. With `minilm-l6` `.verified` and the MCP-side handler registered, `curl POST /v1/embeddings` returns 384-dim vectors that are **NOT** the placeholder's `deterministicVector` pattern (compare two distinct inputs — placeholder produces FNV-1a-seeded SplitMix64 noise; the real model produces semantically-shaped vectors whose cosine similarity to a fixture string aligns with human judgment).
    2. `usage.prompt_tokens` matches `Tokenizer.encode(text:, addSpecialTokens:true).count` for a hand-checked input string (e.g. `"hello world"` → check against `EmbedEngine`'s tokenizer in a tiny harness).
    3. With `minilm-l6` status forced to `.available` (NOT yet downloaded — delete the cached model dir under `~/Documents/huggingface/models/` and restart serve), `POST /v1/embeddings` returns framed `HTTP 503` with `error.type: "model_not_available"` and a body referencing `Models pane` / `senkani doctor`.
    4. With `senkani serve --openai` started WITHOUT the MCP startup hook (e.g. `senkani serve --openai` directly, no MCP target running), `POST /v1/embeddings` falls back to the placeholder and the startup log shows `openai-serve embeddings_backend=placeholder`.
    5. `nm $(which senkani) | grep -cE 'MLXLMCommon|MLXVLM|MLXEmbedders'` returns `0` (CLI binary has zero MLX framework symbols — install-size posture preserved).
- **Pre-condition:** `swift build -c release` succeeds; either MiniLM-L6 downloaded under `~/Documents/huggingface/models/sentence-transformers/all-MiniLM-L6-v2/` (for path 1+2) OR the same dir explicitly removed (for path 3); a provisioned `sk-senkani-…` key with `embeddings` scope (`senkani vault add openai-key --scope embeddings`).
- **Setup:** see the per-item acceptance bullets for the curl shape.
- **Teardown:** revert any `~/Documents/huggingface/models/` state you mutated; `kill` the `senkani serve` process.
- **What lands as evidence:** stdout from each curl (`vectors`, `usage.prompt_tokens`, the 503 body), the `nm` MLX-symbol count, the `openai-serve embeddings_backend=…` startup log line.

---

## Closed — 2026-05-18 — Release v0.3.0 surface-pass (eight new-feature validations on real machine)

`release-v0-3-0-surface-pass` (`affects: manual_validation_needed`) closed across a three-day operator-driven walk 2026-05-16 / 17 / 18. Acceptance roll-up: 4 of 8 lines green (schema migrations v7+v14, DiffViewerPane V.12 hunks + denial annotations + rate cap, quant-frontier 2026-Q2 report after walk-side recovery to durable location, search_web PASS-with-amendment); 4 of 8 lines SPLIT/FAIL surfacing the same Phase-round gap class (Core library + tests shipped without production wiring): T.6 NotificationRouter + MacOSLocalSink zero production callers; V.5c `senkani authorship backfill` audit-chain row + `endSession` silently lost on every run (100 % reproducible — `parent.queue.async` + CLI-exit-before-drain); U.8 `AmplificationGuard.validate` zero production callers, no Schedules pane in SenkaniApp, no `--prose` flag on CLI; V.16 paired-numbers companion stack reachable end-to-end requires T.6c + operator setup. Five findings filed including a **P0 release-blocker** (`authorship-backfill-audit-row-not-durable-2026-05-17`); promote item `release-v0-3-0-promote-changelog-heading` is no longer blocked by `blocked_by` items but is blocked by the new P0 finding by the audit-chain integrity story. Archived at `spec/autonomous/completed/2026/2026-05-18-release-v0-3-0-surface-pass-eight-new-feature-validations-on-real-machine.md`; evidence at `tools/soak/evidence/surface-pass-2026-05-16/`.

---

## Cowork-runnable test plans (groomed; ready to execute)

### phase-t1d-7-operator-ca-install-walk — operator runs the real `senkani doctor --install-egress-ca` (sudo + System Keychain), verifies CONNECT-with-disallowed-body is DENIED with T.5 excerpt, then `--uninstall-egress-ca` restores baseline (2026-06-01)

- **Item:** [`spec/autonomous/backlog/phase-t1d-7-operator-ca-install-walk.md`](../../spec/autonomous/backlog/phase-t1d-7-operator-ca-install-walk.md) — full walk (`## Cowork-runnable test plan (groomed 2026-06-01)`) lives in the item; this is a pointer only.
- **Exec mode:** **operator host Terminal only** — autonomous loop and Cowork sandbox MUST NOT execute this. Touches the System Keychain via `security add-trusted-cert` + admin sudo (the T.1 Notes fence).
- **Pre-condition:** all five blocker items (`phase-t1d-2b-tls-termination-impl`, `phase-t1d-3-body-header-path-matchers`, `phase-t1d-4-body-aware-judge-and-t5-excerpt`, `phase-t1d-5-adversarial-body-corpus-and-doctor`, `phase-t1d-6-install-egress-ca-command`) must be `done` in `spec/autonomous/completed/2026/` before the walk has anything to exercise. As of 2026-06-01: t1d-3 + t1d-6 are done; t1d-2b is `manual`, t1d-4 + t1d-5 are `open` — the walk is GROOMED but not yet RUNNABLE (waits on those three to land).
- **Time estimate:** ~15–25 min operator-supervised (step 1 sudo + Keychain install ≤2 min, step 2 body-deny exercise ~5 min, step 4 uninstall + teardown ~5 min, walk-evidence recording ~5 min).
- **What it proves:** (a) install path persists trust to System Keychain via `security find-certificate` + `security verify-cert` (steps 1.1, 1.2); (b) end-to-end body-inspection denial with T.5 audit row writing `verdict=deny + body_excerpt under cap` (step 2.1) AND allowlisted-host-with-benign-body still passes (step 2.2); (c) browser-trust caveat (Chrome / Firefox have their own stores) documented out-of-scope (step 3); (d) uninstall withdraws trust completely — `find-certificate` returns not-found AND a fresh proxy run fails the TLS handshake because the CA is gone (steps 4.1, 4.2).
- **Recommended path:** copy the step blocks verbatim from the item file; record the SHA-256 fingerprint from check 1.1 and the verbatim outputs of checks 2.1, 4.1, 4.2 into a new `### YYYY-MM-DD — t1d-7 operator CA-install walk` heading above this Cowork-runnable test plans section.
- **Closing the item:** after a PASS-verdict walk, the operator (NOT the autonomous loop) flips frontmatter `status: manual_ready` → `status: done` + adds `shipped: <date-of-walk>`, then `mv`s the item file to `spec/autonomous/completed/<year>/<date>-phase-t1d-7-operator-ca-install-walk.md` and re-runs `python3 tools/autonomous/regen_indexes.py spec`.

### process-gap-prepick-failsafe-sentinel-false-positive-on-self-reference-2026-05-26 — land the single SKILL.md Step 3 match-rule edit (Acceptance bullet 1) that adds the self-reference disambiguation carve-out to the observation-only pre-pick fail-safe, and prove byte-exact landing via the fidelity gate

- **Item:** [`spec/autonomous/backlog/process-gap-prepick-failsafe-sentinel-false-positive-on-self-reference-2026-05-26.md`](../../spec/autonomous/backlog/process-gap-prepick-failsafe-sentinel-false-positive-on-self-reference-2026-05-26.md) — full walk (`## Setup` / `## Execution steps` / `## Acceptance`) lives in the item; this is a pointer only.
- **Parent (in-repo partial-ship 2026-05-26):** the same file's `## Build abort note 2026-05-26`. The partial-ship landed the repo-side portion on `main`: `tools/autonomous/check_observation_only.py` (stdlib matcher with the self-reference disambiguation) + `tools/autonomous/test_check_observation_only.py` (18 tests, green; `tools/autonomous` 84 → 102) + `spec/autonomous/PROCESS.md` `### Self-reference disambiguation (Step 3 fail-safe)` subsection + CHANGELOG v0.4.0 entry. The one remaining acceptance — the SKILL.md Step 3 match-rule edit — is a categorical-block #3 meta-recursive self-edit the loop is harness-denied from applying; the verbatim replacement text is staged in the item's `## Build abort note 2026-05-26 → ### Operator hand-edit`.
- **Exec mode:** **split (Cowork repo-side + operator Terminal for the `~/.claude` edit)** — NOT "either". Steps 1, 9, 10 (staging the verbatim block, the `check_observation_only.py` self-classify + the regression guard) run in Cowork's bash sandbox; steps 2–8 (the SKILL.md edit + `check_verbatim_fidelity.py --target $SK` gate + `grep -c … $SK` counts + the `diff $SK.bak $SK` additivity check) MUST run in the operator's **host Terminal** — Cowork's bash sandbox refuses to mount `~/.claude` (`request_cowork_directory` rejects protected locations). See PROCESS.md `## Split-runtime walks (~/.claude hand-edits)`.
- **Time estimate:** **~7 min operator-supervised** — ~2 min repo-side (staging + helper + regression) + ~5 min operator host Terminal (backup + 1 scripted-insert edit + fidelity gate + counts + additivity); +~3 min if the manual-paste fallback hits the unicode trap and needs one re-stage.
- **What it proves:** (a) the SKILL.md Step 3 match-rule bullet lands **byte-identical** to the staged 19-line REPLACE-WITH block — `check_verbatim_fidelity.py` exit 0, `"identical": true` (step 4); (b) marker counts `grep -c "check_observation_only.py" $SK` = 2 and `grep -c "self-reference to the" $SK` ≥ 1 (steps 5–6 — necessary, not sufficient); (c) additivity — `wc -l $SK` − `wc -l $SK.bak` = 17, one contiguous hunk inside the fail-safe region (steps 7–8); (d) self-classify — `check_observation_only.py` on this item exits 0 / `"is_observation_only": false`, so the fixing item stays buildable under its own new rule (step 9); (e) regression — `tools/autonomous` `test_check_observation_only.py` 18/18 green (step 10).
- **Pre-condition:** repo at `main`; `~/.claude/skills/senkani-autonomous/SKILL.md` readable+writable from the operator's host Terminal and NOT yet edited (`grep -c "check_observation_only.py" $SK` = 0, FIND anchor count = 1); `tools/autonomous/check_observation_only.py` + `tools/autonomous/check_verbatim_fidelity.py` runnable; no leftover `$SK.bak`; Python 3.9+.
- **Recommended path:** the item's idempotent **scripted insert** (a host-Terminal `python3` one-liner that replaces the exact 2-line FIND block with the staged 19-line block) — avoids manual paste of the unicode-heavy block (≤, —, →, …, curly quotes). A manual-paste fallback is documented, gated by the same fidelity helper.
- **Rollback:** `cp ~/.claude/skills/senkani-autonomous/SKILL.md.bak ~/.claude/skills/senkani-autonomous/SKILL.md` (backup captured in Setup before any edit).

---

### process-gap-cowork-sandbox-cannot-mount-claude-dir-for-hand-edit-walks-2026-05-26 — land the three verbatim SKILL.md hand-edits (Acceptance bullets 2 + 3) that carry the split-runtime exec-mode vocabulary, and prove byte-exact landing via the fidelity gate — itself a split-runtime walk that dogfoods this item's own rule

- **Item:** [`spec/autonomous/backlog/process-gap-cowork-sandbox-cannot-mount-claude-dir-for-hand-edit-walks-2026-05-26.md`](../../spec/autonomous/backlog/process-gap-cowork-sandbox-cannot-mount-claude-dir-for-hand-edit-walks-2026-05-26.md) — full walk (`## Setup` / `## Execution steps` / `## Acceptance`) lives in the item; this is a pointer only.
- **Parent (in-repo partial-ship 2026-05-26):** the same file's `## Execution evidence` — partial-ship landed the repo-side portion: `spec/autonomous/PROCESS.md` `## Split-runtime walks (~/.claude hand-edits)` section (Acceptance bullet 1) + the `spec/autonomous-manifest.yaml` `test_plan_groomed` doc-sync note's split vocabulary (Acceptance bullet 3, repo portion) + CHANGELOG v0.4.0 entry. The three SKILL.md self-edits (Acceptance bullet 2 + bullet 3 SKILL portion) are categorical-block #3 meta-recursive self-edits the loop is harness-denied from applying; staged verbatim in the item's `## Build abort note 2026-05-26 → ### Edit 1/2/3`.
- **Exec mode:** **split (Cowork repo-side + operator Terminal for the `~/.claude` edit)** — NOT "either". Steps 1–2 + 12 (staging the payloads, the `tools/autonomous` regression guard) run in Cowork's bash sandbox; steps 3–11 (the SKILL.md edit + `check_verbatim_fidelity.py --target $SK` gate + `diff $SK.bak $SK` negative control + `grep -c … $SK` counts) MUST run in the operator's **host Terminal** — Cowork's bash sandbox refuses to mount `~/.claude` (`request_cowork_directory` rejects protected locations). This walk is the canonical dogfood for PROCESS.md `## Split-runtime walks (~/.claude hand-edits)`.
- **Time estimate:** **~13 min operator-supervised** — ~3 min repo-side (staging + pre-condition asserts + regression guard) + ~10 min operator host Terminal (backup + 3 hand-edits + 3 fidelity gates + counts + negative control).
- **What it proves:** (a) all three SKILL.md edits land **byte-identical** to the staged `/tmp/sk-edit{1,2,3}.txt` payloads — `check_verbatim_fidelity.py` exit 0 ×3 (steps 7–9); (b) marker counts `grep -c "split (Cowork repo-side + operator Terminal"` = 3 and `grep -c "Split-runtime walks"` = 3 (step 10 — necessary, not sufficient); (c) negative control — `diff $SK.bak $SK` = 5 removed + 11 added, net +6, no collateral region (step 11); (d) regression — `tools/autonomous` suite 102/102 green (step 12); (e) split-runtime dogfood — which steps ran repo-side vs operator host Terminal is recorded.
- **Pre-condition:** repo at `main`; `spec/autonomous/PROCESS.md` `## Split-runtime walks` present + manifest split vocabulary count = 2 (both shipped by the partial-ship build round); `~/.claude/skills/senkani-autonomous/SKILL.md` readable+writable from the operator's host Terminal and NOT yet edited (`grep -c "split (Cowork repo-side + operator Terminal" $SK` = 0); `tools/autonomous/check_verbatim_fidelity.py` runnable; Python 3.9+.
- **Rollback:** `cp ~/.claude/skills/senkani-autonomous/SKILL.md.bak ~/.claude/skills/senkani-autonomous/SKILL.md` (backup captured in Setup before any edit).

---

### process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26 — land the SKILL.md `### Groomed body template` "Verbatim hand-edit fidelity" pattern (Acceptance bullet 1) and prove it landed byte-exact by dogfooding the `check_verbatim_fidelity.py` helper this item shipped 2026-05-26

- **✅ EXECUTED + CLOSED 2026-05-26:** walk ran clean end-to-end via the recommended scripted insert (no manual paste). Fidelity gate exit **0** `identical: true` (staged 29 / landed 29); additivity 0 deletion lines; negative control (dropped line) exit **1** `line_count_mismatch`; regression 79/79. All 9 `## Acceptance` boxes ✅; item closed to `completed/2026/`. **Finding filed:** `process-gap-cowork-sandbox-cannot-mount-claude-dir-for-hand-edit-walks-2026-05-26` — the host-side steps (the `~/.claude/...SKILL.md` edit + fidelity gate + additivity + negative control) had to run in the operator's Terminal, not Cowork's bash sandbox, because Cowork refuses to mount `~/.claude` (protected location); the "exec mode: either" label below was therefore inaccurate for the `~/.claude`-side steps. Evidence in the item's `### Operator hand-edit verification 2026-05-26`.
- **Item:** [`spec/autonomous/backlog/process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26.md`](../../spec/autonomous/backlog/process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26.md) — full walk (`## Setup` / `## Execution steps` / `## Acceptance`) lives in the item; this is a pointer only.
- **Parent (in-repo partial-ship 2026-05-26):** the same file's `## Execution evidence` — partial-ship landed `tools/autonomous/check_verbatim_fidelity.py` (stdlib helper) + `tools/autonomous/test_check_verbatim_fidelity.py` (12 tests, green) + `spec/autonomous/PROCESS.md` `## Verbatim-fidelity check (hand-edit walks)` section + CHANGELOG v0.4.0 entry. Acceptance bullets 2/3/4 shipped there; only bullet 1 (the SKILL.md hand-edit) remains. Staged verbatim text is in the item's `## Build abort note 2026-05-26 → ### Edit 1`.
- **Exec mode:** **cowork or operator — either** (entirely shell/Bash; no GUI, no screenshot, no TCC, no first-grant). Recommended path is the item's idempotent scripted insert; a manual-paste path is documented and gated by the same fidelity helper.
- **Time estimate:** **~10 min operator-supervised** (~5 min scripted-insert path; +~5 min if hand-pasting / one re-stage on the trailing-blank trap).
- **What it proves:** (a) the "Verbatim hand-edit fidelity" pattern lands in SKILL.md's `### Groomed body template` (grep count 1; `check_verbatim_fidelity.py` ≥1); (b) **fidelity gate** — the landed block is byte-identical to the staged source (`check_verbatim_fidelity.py` exit 0, `identical: true`); (c) additivity — 0 deletion lines vs `SKILL.md.bak`; (d) **negative control** — corrupting the staged copy makes the gate exit 1 (`line_count_mismatch`), proving the gate catches infidelity; (e) regression — `tools/autonomous` suite 79/79 green, PROCESS.md section intact; (f) parent item untouched.
- **Determinism note:** the staged file must be **29 splitlines (28 content + 1 trailing blank)** — the gate's end-exclusive extraction at `^## Acceptance` includes the markdown blank before the heading. The item's Setup encodes this (`printf '\n' >> /tmp/edit1-verbatim.txt`); verified empirically this groom round.
- **Rollback:** `cp ~/.claude/skills/senkani-autonomous/SKILL.md.bak ~/.claude/skills/senkani-autonomous/SKILL.md` (backup captured by the scripted insert / Setup before any edit).

---

### process-gap-pre-audit-cli-protocol-match-check-2026-05-22 — validate the operator-pasted SKILL.md edits (scope-groom phase 5.7 + build-mode Step 2.5 wiring of `check_external_surfaces.py`) actually land verbatim in `~/.claude/skills/senkani-autonomous/SKILL.md` AND the helper's exit-code contract survives the edits 2026-05-26

- **✅ EXECUTED + CLOSED 2026-05-26:** walk run; both SKILL.md edits landed **byte-exact verbatim** (scope-groom 5.7 + build-mode 2.5). 9/10 acceptance boxes green; box 9 (wasm-case helper self-fire, `exit 1`) waived as a stale expectation — the helper scans only `## Acceptance` and the groom round had moved this item's framing vocabulary into `## Pre-grooming notes`, so the helper correctly returns `exit 0`. Edit 1 applied via Claude `Edit` before the auto-mode self-modification classifier engaged; Edit 2 denied to Claude (the anticipated meta-recursive denial) and applied via a sibling agent + an operator-run correction to reach verbatim. Item closed to `completed/2026/`. Follow-ups filed: `process-gap-pre-audit-cli-protocol-match-check-2026-05-22-followup-step9-stale-expectation-2026-05-26` + `process-gap-operator-hand-edit-verbatim-fidelity-unverified-2026-05-26`. Evidence in the item's `### Operator hand-edit verification 2026-05-26`.
- **Item:** [`spec/autonomous/backlog/process-gap-pre-audit-cli-protocol-match-check-2026-05-22.md`](../../spec/autonomous/backlog/process-gap-pre-audit-cli-protocol-match-check-2026-05-22.md)
- **Parent (in-repo partial-ship 2026-05-26):** the same file's `## Execution evidence` section — partial-ship landed `tools/autonomous/check_external_surfaces.py` (stdlib helper, 484 lines) + `tools/autonomous/test_check_external_surfaces.py` (10 tests, all green) + `spec/autonomous/PROCESS.md` `## Pre-audit external surfaces` schema section + CHANGELOG v0.4.0 entry. This groom round queues the test plan that validates the SKILL.md edit text (preserved verbatim in the same item's `## Build abort note 2026-05-26` for operator copy-paste).
- **Exec mode:** **operator (or cowork) — either** (mix of `shell` for verification + `gui (human)` for the two text-editor insertions; no TCC, no first-grant). Cowork can drive the editor via screenshot+click, but a careful operator using vim/VS Code/Cursor is the simpler path.
- **Time estimate:** **8-11 min operator-supervised** — ~3 min shell verification + ~5-8 min text-editor work for the two insertions. Backup + sha-fingerprint capture before edit gives a clean rollback if anything goes sideways.
- **What it proves:** (a) operator pasted SKILL.md Edit 1 (scope-groom phase 5.7) verbatim into the `### Phase order (scope-groom mode)` block between phases 5 and 6 — step 5 + step 6 awk-scoped grep; (b) operator pasted SKILL.md Edit 2 (build-mode Step 2.5) verbatim into the `### Phase order (build mode)` block between phases 2 and 3 — step 5 + step 6 awk-scoped grep; (c) the diff is purely additive — step 10 confirms zero deletion lines outside diff headers (Torvalds invariant: no accidental removals); (d) helper still 10/10 green post-edit — step 7 (the SKILL.md edits cannot regress the helper, but a pre/post comparison anchors the audit trail); (e) helper's exit-code contract intact — step 8 (clean item → exit 0) + step 9 (wasm-case → exit 1 with `vocabulary_without_surface` reason).
- **Pre-condition:** `~/.claude/skills/senkani-autonomous/SKILL.md` readable and NOT yet edited (`grep -c check_external_surfaces` returns 0). `tools/autonomous/check_external_surfaces.py` + `tools/autonomous/test_check_external_surfaces.py` present. `spec/autonomous/PROCESS.md` contains `## Pre-audit external surfaces` heading. Pre-edit tests show 10/10 green. No leftover `SKILL.md.bak` from a prior partial-walk (otherwise abort or rollback first). Python 3.9+ on PATH. Working directory `/Users/clank/Desktop/projects/senkani`.
- **Validates:**
  - **(a) Both edits present (count + position) (steps 5-6)** — `grep -c "check_external_surfaces" ~/.claude/skills/senkani-autonomous/SKILL.md` returns exactly `2`; `awk '/^### Phase order \(scope-groom mode\)/,/^### Scope-groom-mode close phase/' SKILL.md | grep -c check_external_surfaces` returns `1`; same shape for build-mode phase block returns `1`.
  - **(b) Diff purely additive (step 10)** — `diff -u SKILL.md.bak SKILL.md` shows exactly 2 hunks, zero deletion lines outside `---` headers; `grep -c '^-[^-]' diff.txt` returns `0`.
  - **(c) Helper 10/10 post-edit (step 7)** — `python3 tools/autonomous/test_check_external_surfaces.py 2>&1 | tail -3` ends with `OK` AND `Ran 10 tests in <time>s`.
  - **(d) Clean-item exit 0 (step 8)** — helper on `process-gap-decompose-mode-duplicate-tests-delta-docs-synced-2026-05-22` exits `0` with `"should_fire": false`, empty `reasons`.
  - **(e) Wasm-case exit 1 (step 9)** — helper on this item exits `1` with `"should_fire": true` and exactly one reason of `kind: "vocabulary_without_surface"`.
  - **(f) Pre/post fingerprints captured** — `/tmp/skill-md-pre-edit.sha256` + `/tmp/skill-md-post-edit.sha256` differ; line count delta ≥ 30.
- **Rollback:** `cp ~/.claude/skills/senkani-autonomous/SKILL.md.bak ~/.claude/skills/senkani-autonomous/SKILL.md` if any acceptance check fails; the backup is captured in Setup before any edit.

---

### process-gap-close-mode-execution-evidence-invariant-vs-decomposed-parent-contract-2026-05-23 — validate the operator-pasted SKILL.md Option-C edits (Step 2 close-mode auto-stub clause + Decompose-mode `## Operator contract` template update) actually fire on a synthetic decomposed-parent fixture + the in-repo validator recognizes the auto-stub format 2026-05-24

- **Item:** [`spec/autonomous/backlog/process-gap-close-mode-execution-evidence-invariant-vs-decomposed-parent-contract-2026-05-23.md`](../../spec/autonomous/backlog/process-gap-close-mode-execution-evidence-invariant-vs-decomposed-parent-contract-2026-05-23.md)
- **Parent (in-repo partial-ship 2026-05-24):** the same file's `## Execution evidence 2026-05-24` section — partial-ship landed `classify_evidence_section` + `check_decomposed_completed_evidence` extensions to `tools/autonomous/check-backlog-statuses.py` (commit `89e1239`) along with 4 new tests in `tools/autonomous/test_check_backlog_statuses.py`. This groom round queues the test plan that validates the SKILL.md edit text (preserved verbatim in the same item's `## Build abort note 2026-05-24` for operator copy-paste).
- **Exec mode:** **cowork or operator — either** (entirely shell-driven; 6 mandatory steps + 1 optional, all `grep` / `printf` / `python3` / `mktemp` / `rm -rf`; no GUI, no TCC, no first-grant). Cowork's Bash subagent runs the whole plan; operator can paste inline too.
- **Time estimate:** **≤ 5 min operator-supervised** — sub-second validator runs at steps 4 + 6; ~10-30s per other step including scratch tree setup.
- **What it proves:** (a) operator pasted SKILL.md edit (a) — `## Step 2 — Close-mode sweep` contains "Auto-stub exception" phrase (step 1 grep); (b) operator pasted SKILL.md edit (b) — `### Decompose-mode parent body template` `## Operator contract` contains "Evidence is auto-stubbed by the close-mode sweep" (step 2 grep); (c) validator's `check_decomposed_completed_evidence` correctly flags a decomposed-parent fixture WITHOUT `## Execution evidence` (step 4 — exit 1 + sentinel text); (d) validator accepts the auto-stub format when appended (step 6 — exit 0 + `OK`); (e) optional step 7 confirms operator-written non-stub evidence ALSO passes (Option C accepts either format).
- **Pre-condition:** `~/.claude/skills/senkani-autonomous/SKILL.md` readable; operator has pasted both edit blocks from the item's `## Build abort note 2026-05-24` section (otherwise steps 1-2 fail and the plan halts with the failure-mode recovery row pointing back to the build-abort-note text). Repo at or past commits `89e1239` (Option-C validator) and `5963e2b` (V.17a-7 shared helper extraction). Python 3.9+ on PATH. The plan uses scratch trees under `mktemp -d /tmp/senkani-v17a7-groom-XXXXXX` so it never touches the live `spec/autonomous/` tree.
- **Validates:**
  - **(a) SKILL.md edit (a) applied (step 1)** — `grep -c "Auto-stub exception" ~/.claude/skills/senkani-autonomous/SKILL.md` returns ≥ 1.
  - **(b) SKILL.md edit (b) applied (step 2)** — `grep -c "Evidence is auto-stubbed by the close-mode sweep" ~/.claude/skills/senkani-autonomous/SKILL.md` returns ≥ 1.
  - **(c) validator flags missing-evidence decomposed parent (step 4)** — exit 1 + stdout contains both `no \`## Execution evidence\`` AND `Option-C close-mode auto-stub`.
  - **(d) validator accepts auto-stub format (step 6)** — exit 0 + stdout contains `OK`.
  - **(e) [optional] validator accepts operator-written evidence (step 7)** — exit 0 + stdout contains `OK` (proves `classify_evidence_section` returns "operator" for non-stub text and the check still passes).

---

### process-gap-decompose-mode-duplicate-tests-delta-docs-synced-2026-05-22 — validate the operator-pasted SKILL.md edits (groom / decompose / scope-groom close-phase step 1 "Add" → "Set or replace" rewording) actually prevent the duplicate-key class via grep + live-tree roundtrip + synthetic duplicate-key probe 2026-05-23

- **Item:** [`spec/autonomous/backlog/process-gap-decompose-mode-duplicate-tests-delta-docs-synced-2026-05-22.md`](../../spec/autonomous/backlog/process-gap-decompose-mode-duplicate-tests-delta-docs-synced-2026-05-22.md)
- **Parent (in-repo file fix + roundtrip-green shipped 2026-05-22):** the same file's `## Execution evidence (in-repo partial-ship 2026-05-22)` section — partial-ship landed the cleanup of `phase-u2b-1b-headless-wkwebview-impl.md` and proved `roundtrip.py` Pass 0 green; this groom round queues the test plan that validates the SKILL.md edit text (preserved verbatim in the same item's `## Build abort note 2026-05-22` for operator copy-paste).
- **Exec mode:** **cowork or operator — either** (fully shell-driven; eight `grep` / `python3` invocations + Setup + Teardown; no GUI, no TCC, no first-grant). Cowork's Bash subagent runs the entire plan; operator can also run inline.
- **Time estimate:** **~5 min operator-supervised** — eight quick steps including the synthetic-tree build at Step 7. No caches to warm.
- **What it proves:** (a) the operator has actually pasted the three SKILL.md edits from the item's `## Build abort note 2026-05-22` section (Steps 1-4 grep for "Set or replace" patterns); (b) no stale "Add `<recurring-key>:`" residue lines remain (Step 5); (c) the live `spec/autonomous/` tree is duplicate-key-clean (Step 6 — `tools/autonomous/roundtrip.py` Pass 0 green); (d) the regression check itself still detects duplicates (Step 7 — a synthetic temp tree with intentional duplicate `tests_delta:` keys triggers FAIL with non-zero exit).
- **Pre-condition:** `~/.claude/skills/senkani-autonomous/SKILL.md` readable; operator has pasted the three edit blocks from the item's `## Build abort note 2026-05-22` section (otherwise Steps 1-4 return 0 hits and the plan reports "operator hasn't pasted yet"). `tools/autonomous/roundtrip.py` present in the project tree. Python 3.9+ on PATH. The plan uses direct `> file 2>&1; echo $?` (not `| tee`) so exit-code capture stays portable across bash + zsh.
- **Validates:**
  - **(a) SKILL.md edits applied (Steps 1-4)** — `grep -c "Set or replace \`tests_delta:" $SKILL_MD` returns ≥ 3 (one each in groom / decompose / scope-groom close-phase sections); same for `docs_synced:`; `decomposed:` returns ≥ 1; `scope_groomed:` returns ≥ 1.
  - **(b) No "Add `<recurring-key>:`" residue (Step 5)** — `grep -cE '^[[:space:]]+-[[:space:]]+Add \`(tests_delta|docs_synced|groomed|groomed_by|decomposed|decomposed_by|split_into|scope_groomed|scope_groomed_by):' $SKILL_MD` returns 0.
  - **(c) Live tree duplicate-key clean (Step 6)** — `python3 tools/autonomous/roundtrip.py > out 2>&1; echo $?` returns 0 and `out` contains "PASS".
  - **(d) Synthetic probe still detects duplicates (Step 7)** — build a temp `spec/autonomous/backlog/` tree containing one file with two `tests_delta:` keys; `python3 tools/autonomous/roundtrip.py "$SYN/spec" > out 2>&1; echo $?` returns 1 (non-zero) and `out` contains "duplicate key 'tests_delta'".
- **Failure modes covered in the plan body:** Steps 1-4 returning 0 hits → operator hasn't pasted yet (refer back to the item's `## Build abort note 2026-05-22`); Step 5 returning ≥ 1 residual "Add" hit → partial paste, missing line; Step 6 FAIL on current tree → new duplicate-key violation slipped in since 2026-05-22; Step 7 NOT triggering FAIL → P1 follow-up immediately (regression check broke); footgun re passing `$SYN/spec/autonomous` instead of `$SYN/spec` explicitly documented (script appends `/autonomous` internally).
- **Operator contract:** standard groomed template — paste captured `$EVIDENCE_DIR/*.txt` outputs into a `## Execution evidence (operator/cowork run <date>)` section appended below the existing `## Operator contract`, flip `status: manual_ready → done` + `shipped: <today>`, then `/senkani-autonomous` close-mode finalizes.

### process-gap-u2b-1b-6-runtime-parity-validation-2026-05-22 — prove `BrowserPaneRunner` (off-screen WKWebView) and `PlaywrightSubprocessRunner` (node + Playwright + Chromium) produce byte-equivalent `Response` payloads on the four parity-relevant fields when driven against the same `target_url` through the production MCP transport, on two real local fixtures (design-roundtrip.html + security-roundtrip.html) 2026-05-22

- **Item:** [`spec/autonomous/backlog/process-gap-u2b-1b-6-runtime-parity-validation-2026-05-22.md`](../../spec/autonomous/backlog/process-gap-u2b-1b-6-runtime-parity-validation-2026-05-22.md)
- **Parent (parity corpus shipped):** [`spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-6-dispatcher-wire-and-parity-corpus.md`](../../spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-6-dispatcher-wire-and-parity-corpus.md)
- **Exec mode:** **cowork or operator — either** (fully shell-driven; the off-screen WKWebView is invisible by construction; no GUI capture required — every observation is shell-tail / JSON file / pgrep diff). `mcp__senkani__exec` is sufficient. No TCC dialog, no sudo, no first-grant required.
- **Time estimate:** **~12-18 min operator-supervised** cold (~3-5 min Setup including cold `swift build --product SenkaniApp` + one-time `npm install` / `playwright install chromium` if not yet on the machine; ~6-10 min Execution across Steps 1-8; ~2-3 min Teardown). Steady-state with caches pre-warmed: ~8-12 min total.
- **What it proves:** the U.2b-1b-6 parity corpus's stub-driven byte-shape parity (`Tests/SenkaniTests/BrowserPaneRunnerParityTests.swift` — both arms exercised via closure stubs returning identical canned `PlaywrightResult` values) extends to the runtime contract: when driven against the same fixture URL through the production MCP transport (`.build/debug/SenkaniApp --mcp-server` + `tools/call name: "validate_browser"` + `dispatch: subprocess|headless`), the two real runners emit `result_status`, `axes_run`, `assertions_passed`, `assertions_failed` byte-identically. `screenshot_path` is expected to legitimately differ across arms (runner-specific path conventions); `advisory` is expected byte-identical on `pass` (per `formatAdvisory`'s pass-case contract at `Sources/Core/Validation/BrowserValidationDispatcher.swift:486-487`) and may differ on `fail`/`partial` — both fields are captured but NOT part of the parity-pass criterion.
- **Pre-condition:** HEAD descendant of commit `bed4e03` (close: `process-gap-index-html-test-count-drift-2026-05-22`) — must include `BrowserPaneRunner.swift` + `BrowserPaneRunnerParityTests.swift`. `swift build --product SenkaniApp` green. Playwright Chromium cache at `~/Library/Caches/ms-playwright/chromium-*` exists (Setup installs once if absent — ~150MB). `Resources/playwright-runner/node_modules/playwright/` present (Setup runs `npm install` once if absent). `node`, `python3`, `jq`, `lsof`, `pgrep` on PATH. Port `$FIXTURE_PORT` (default `8765`) free.
- **Validates:**
  - **(a) MCP transport health both arms (Steps 1-4)** — `tools/call` with `name: "validate_browser"` resolves for both `dispatch=subprocess` AND `dispatch=headless`. Driver injects `SENKANI_PANE_ID` env (synthesised UUID per run) so the MCP server's access gate at `Sources/MCP/MCPMain.swift:22` activates. Neither arm carries `advisory: "headless_not_yet_implemented"` (factory wire regression) nor `validation_browser_missing` (subprocess cache regression).
  - **(b) Both arms `result_status: "pass"`** on `design-roundtrip.html` (subprocess Step 1 + headless Step 2) AND on `security-roundtrip.html` (subprocess Step 3 + headless Step 4). Either fixture flipping to `fail` invalidates the parity-pass narrative; per-fixture finding filed.
  - **(c) Per-fixture parity diff is EMPTY** on the four byte-relevant fields. Step 6 runs `diff -u design-subprocess.parity.json design-headless.parity.json` + same for security; both `.parity.diff` files must be zero bytes. **Any non-empty diff is a finding** (P1 for `axes_run` / count mismatch; P0 for `result_status` divergence on the same fixture).
  - **(d) `advisory` byte-identical on `pass`** — Step 7 cross-check: each fixture's subprocess advisory == headless advisory, matching `formatAdvisory`'s `"browser_validation_passed: axes=<comma-joined-sorted>"` contract. **A mismatch on a `pass` is a P0 finding** (`process-gap-browserpanerunner-advisory-divergence-on-pass-<RUN_TS>`) — would mean the dispatcher's formatter regressed OR a runner returned non-pass despite `assertions_failed == 0`.
  - **(e) `screenshot_path` documented per arm** — OFF the parity-pass criterion (legitimately differs), but Step 7 records both arms' values so any future "but wait, parity also extends to screenshot" claim has a baseline to point at.
  - **(f) No leaked WebKit content processes (Step 8)** — after Steps 2 + 4, `pgrep -fl com.apple.WebKit.WebContent` is identical to the Setup baseline (the two `BrowserPaneRunner.run(...)` calls deallocated cleanly via `LifecycleHandle.tearDownSync()`).
- **Audit-accepted risks (Russell / Sutton / Bach groom round 2026-05-22):**
  - Russell — `screenshot_path` is INTENTIONALLY off the parity-pass criterion (runner-specific conventions; driver passes `screenshot: false` so both arms emit nil); documented in Pre-grooming notes. `advisory` on pass is byte-identical contract per `formatAdvisory`; mismatch is a P0 filing not silent acceptance.
  - Sutton — walk parallels U.2b-1b-4 + U.2b-1b-5 shape (MCP-driver convention, evidence-bundle tar, fixture HTTP server on localhost, RUN_DIR + RUN_TS convention, failure-mode-routes-to-named-filings discipline). Cross-walk operator muscle memory preserved.
  - Bach — synthetic-fixture coverage gap (perf + completeness axes have no native fixture); two-fixture coverage (design + security) is sufficient because each fixture runs ALL four axes per the dispatcher's default-all-axes plan. Deferred follow-up named for perf+completeness fixture coverage if operator wants finer-grained validation.
- **Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings to named follow-up filings before retry:** `process-gap-u2b-1b-6-parity-divergence-<fixture>-<RUN_TS>` (Step 6 diff non-empty; one filing per fixture × axis-of-divergence); `process-gap-u2b-1b-6-runner-fail-<fixture>-<RUN_TS>` (a runner returns `fail` on a happy-path fixture); `process-gap-browserpanerunner-factory-not-registered-<RUN_TS>` (Step 2/4 returns `headless_not_yet_implemented`); `process-gap-playwright-install-incomplete-<RUN_TS>` (Step 1/3 returns `validation_browser_missing` after Setup ran the install); **`process-gap-browserpanerunner-advisory-divergence-on-pass-<RUN_TS>` (Step 7 mismatch — P0 wiring-bypass)**; `process-gap-browserpanerunner-webcontent-leak-<RUN_TS>` (Step 8 leak verdict non-empty). Teardown is mandatory even on failure (kills fixture server, sweeps lingering SenkaniApp / WebContent processes).
- **Cross-walk note (groom 2026-05-22, corrected 2026-05-22):** this walk's `mcp-driver.py` heredoc uses the bare wire name `validate_browser` (NOT the `senkani_`-prefixed UI-display form some Claude-Code surfaces show) and injects `SENKANI_PANE_ID` via `env.setdefault(…, str(uuid.uuid4()))` so the MCP server's access gate activates. The U.2b-1b-4 + U.2b-1b-5 walks above carried latent defects on both points at filing; build round [`process-gap-walks-mcp-driver-corrections-2026-05-22`](../../spec/autonomous/backlog/process-gap-walks-mcp-driver-corrections-2026-05-22.md) corrected their heredocs to match this walk's pattern. All three walks are now cross-walk consistent.
- Groomed 2026-05-22 by `senkani-autonomous`; awaits operator/Cowork execution → flip `status: manual_ready` → `status: done` + paste evidence into `## Execution evidence` → run `/senkani-autonomous` so the next round's close-mode sweep finalizes.

### process-gap-browserpanerunner-runtime-validation-2026-05-22 — prove `.build/debug/SenkaniApp --mcp-server` routes a `dispatch=headless` call all the way through `BrowserPaneRunner` (off-screen WKWebView allocates + 4-axis evaluateJavaScript returns valid PlaywrightResult + per-axis timeout fires + WebKit content processes clean up) against the design-roundtrip.html fixture 2026-05-22

- **Item:** [`spec/autonomous/backlog/process-gap-browserpanerunner-runtime-validation-2026-05-22.md`](../../spec/autonomous/backlog/process-gap-browserpanerunner-runtime-validation-2026-05-22.md)
- **Parent (runtime shipped):** [`spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-4-swift-browserpanerunner-lifecycle.md`](../../spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-4-swift-browserpanerunner-lifecycle.md) + [`spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-6-dispatcher-wire-and-parity-corpus.md`](../../spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-6-dispatcher-wire-and-parity-corpus.md)
- **Exec mode:** **cowork or operator — either** (fully shell-driven; the off-screen WKWebView is invisible by construction; the only optional GUI surface is a Console.app screenshot for Step 6, satisfied by either Cowork-native `mcp__computer-use__screenshot` OR text-state `pgrep` diff). `mcp__senkani__exec` is sufficient. No TCC dialog, no sudo, no first-grant required.
- **Time estimate:** **~10-15 min operator-supervised** (~2-3 min Setup including `swift build --product SenkaniApp` + fixture HTTP server + hang-fixture write; ~5-8 min Execution across Steps 1-6; ~2-3 min Teardown). Cold `swift build` from a clean `.build/` adds ~3-5 min.
- **What it proves:** the U.2b-1b-4 / -5 / -6 stack lights up end-to-end through the production MCP transport: `BrowserPaneRunnerFactory.register()` at `SenkaniApp/App/main.swift:18`, MCP `validate_browser` with `dispatch=headless`, `BrowserDispatchRegistry.headlessRunnerFactory` resolves, `BrowserPaneRunner` allocates the off-screen NSWindow at content rect `(-10000, -10000, 1280, 800)`, WKWebView loads the fixture, four-axis `evaluateJavaScript` returns a valid `PlaywrightResult` with `axes_run` sorted alphabetical (Steps 1-2), WebKit content processes actually spawn (Step 3), the per-axis timeout (`defaultAxisTimeout = 15.0s`) fires on a hang fixture rather than parking the run thread (Step 4), and no content processes leak (Steps 3 + 6). The structural test at `Tests/SenkaniTests/BrowserPaneRunnerContractTests.swift` only proves source-shape presence; `swift test` cannot exercise the runtime because `SenkaniApp` is an `executableTarget` not linked from `SenkaniTests`.
- **Pre-condition:** HEAD descendant of commit `bed4e03` (close: `process-gap-index-html-test-count-drift-2026-05-22`) — must include `BrowserPaneRunner.swift` and `BrowserPaneRunnerFactory.swift`. `swift build --product SenkaniApp` green. `python3`, `jq`, `lsof`, `pgrep` on PATH. Port `$FIXTURE_PORT` (default `8765`) free (override via env). No stale SenkaniApp / WebKit-WebContent processes (Setup verifies + clears).
- **Validates:**
  - **(a) MCP transport health (Step 1)** — `.build/debug/SenkaniApp --mcp-server`'s `tools/list` enumerates `validate_browser` (bare wire name — `senkani_` prefix is a Claude-Code UI-display convention, not on the wire; `ToolRegistry.byName` is exact-match per `Sources/MCP/ToolRegistry.swift:388-390`); the `tools/call` against `http://127.0.0.1:$FIXTURE_PORT/design-roundtrip.html` with `dispatch=headless` returns a structured `PlaywrightResult` (not `headless_not_yet_implemented` — which would mean the factory wasn't registered). The corrected `mcp-driver.py` heredoc auto-injects `SENKANI_PANE_ID` (synthesized UUID per run) into the spawned subprocess env, satisfying `MCPServerRunner.run()`'s access gate at `Sources/MCP/MCPMain.swift:22` — without that injection the server exits 0 silently and the driver's first `readline` blocks.
  - **(b) End-to-end happy path (Step 2)** — `result_status: "pass"`, `axes_run == ["completeness","design","perf","security"]` (alphabetical, all four), `assertions_failed == 0`, `assertions_passed >= 4`, advisory contains no fault substrings.
  - **(c) WKWebView actually allocates (Step 3)** — during or as a result of the `tools/call`, `pgrep -fl com.apple.WebKit.WebContent` shows ≥1 new content process beyond the Setup baseline; proves the off-screen NSWindow + WKWebView lifecycle actually fires, not stubbed.
  - **(d) Per-axis timeout fires (Step 4)** — re-run against `hang-roundtrip.html` (busy-loop blocks LCP for 60s) returns within ~90s wall clock with `result_status: "fail"` and advisory containing `evaluate_timeout` OR `page_load_timeout`. **A `pass` or a >120s park is a P0 finding (`process-gap-browserpanerunner-axis-timeout-not-honored-<RUN_TS>`) — do NOT close the walk PASS.**
  - **(e) No leaked WebKit content processes (Step 6)** — after Step 4, `pgrep -fl com.apple.WebKit.WebContent` is identical to the Setup baseline (diff exits 0). Captured as a text-state file OR Cowork-native `mcp__computer-use__screenshot` of Console.app filtered to `WebContent`.
- **Audit-accepted risks (Bach / Russell / Sutton groom round 2026-05-22):**
  - Bach — Step 3's "WebContent process spawned" check is timing-sensitive: content processes can finish quickly. Mitigation: Step 4's hang-fixture run holds the WebView for ~15s+ so the `pgrep` capture has a wide window. If Step 3-during fails but Step 4-during succeeds, the operator may pass Step 3.
  - Russell — Step 4's advisory may be either `evaluate_timeout` OR `page_load_timeout`; both indicate the runner hit a deadline and aborted gracefully. WKWebView delivers the deadline on either the navigation-load callback OR the per-axis `evaluateJavaScript` depending on whether the busy-loop preempts LCP. The walk's pass criterion accepts either.
  - Sutton — bundle-vs-unbundled distinction: this walk uses `.build/debug/SenkaniApp` directly. NO `tools/soak/runner/SenkaniApp.app` bundle needed (`--mcp-server` mode runs unbundled). Documented in Cowork hints — parity with the egress-runtime walk below.
- **Acceptance scoping (groom 2026-05-22):** the original filing had seven bullets; three (direct `tabWalkFocusOrder`, main-thread deadlock demonstration, `NSApplication.shared.windows` count introspection) cannot be exercised through MCP — those are deferred to follow-up [`process-gap-browserpane-direct-api-exerciser-2026-05-22`](../../spec/autonomous/backlog/process-gap-browserpane-direct-api-exerciser-2026-05-22.md) which ships a small `tools/browserpane-exerciser/` Swift `executableTarget`. The MCP path *is* the production-callable runtime surface, so its end-to-end greenness is the load-bearing evidence.
- **Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings to named follow-up filings before retry:** `process-gap-browserpanerunner-factory-not-registered-<RUN_TS>` (Step 1 returns `headless_not_yet_implemented` — wrong binary or factory wire regression); `process-gap-browserpanerunner-runtime-crash-<RUN_TS>` (Step 1 hangs > 60s with WKWebView crash); `process-gap-browserpanerunner-axes-order-regression-<RUN_TS>` (Step 2 `axes_run` not alphabetical); `process-gap-browserpanerunner-webcontent-not-spawning-<RUN_TS>` (Step 3 zero WebContent during call — stubbed runner = silent acceptance, P0); `process-gap-browserpanerunner-webcontent-leak-<RUN_TS>` (Step 6 leaked processes); **`process-gap-browserpanerunner-axis-timeout-not-honored-<RUN_TS>` (Step 4 doesn't time out — P0 wiring bypass)**. Teardown is mandatory even on failure (kills fixture server, removes the transient hang-roundtrip.html, sweeps any stale SenkaniApp `--mcp-server` process).
- Groomed 2026-05-22 by `senkani-autonomous`; awaits operator/Cowork execution → flip `status: manual_ready` → `status: done` + paste evidence into `## Execution evidence` → run `/senkani-autonomous` so the next round's close-mode sweep finalizes.

### process-gap-browserpanerunner-egress-runtime-validation-2026-05-22 — prove off-screen WKWebView traffic tunnels through the EgressProxy daemon, prove the daemon-down test falsifies bypass, prove the override-policy file lifecycle holds 2026-05-22

- **Item:** [`spec/autonomous/backlog/process-gap-browserpanerunner-egress-runtime-validation-2026-05-22.md`](../../spec/autonomous/backlog/process-gap-browserpanerunner-egress-runtime-validation-2026-05-22.md)
- **Parent (egress wiring shipped):** [`spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-5-wkwebsitedatastore-egress-proxy-wiring.md`](../../spec/autonomous/completed/2026/2026-05-22-phase-u2b-1b-5-wkwebsitedatastore-egress-proxy-wiring.md)
- **Exec mode:** **cowork or operator — either** (fully shell-driven; no GUI surfaces — the off-screen WKWebView is invisible by construction at content rect `(-10000, -10000, 1280, 800)`). Every observation is shell-tail / JSON file / log line; `mcp__senkani__exec` is sufficient. No TCC dialog, no sudo, no first-grant required.
- **Time estimate:** **~10-15 min operator-supervised** (~2-3 min Setup including `swift build --product SenkaniApp` + `swift build --product senkani` + tight test policy write + fixture HTTP dir + baseline override-file snapshot; ~5-8 min Execution across Steps 1-7; ~2-3 min Teardown). Cold `swift build` from a clean `.build/` adds ~3-5 min.
- **What it proves:** the U.2b-1b-5 egress wiring in `SenkaniApp/Services/BrowserPaneRunner.swift` (`egressProxyURL: URL?` slot + `makeProxyConfiguration` helper producing `Network.ProxyConfiguration(httpCONNECTProxy:...)` + `WKWebsiteDataStore.proxyConfigurations = [proxy]` on the non-persistent data store BEFORE WKWebView allocation + `writeEgressOverridePolicy(targetURL:proxyURL:)` per-target file write with `defer`-based cleanup) actually tunnels off-screen WKWebView traffic through the EgressProxy daemon. The runtime acceptance bullet U.2b-1b-5's close carried forward as a mandatory follow-up (the structural test at `Tests/SenkaniTests/BrowserPaneRunnerEgressWiringTests.swift` only proves source-shape presence; `SenkaniApp` is an `executableTarget` not linked from `SenkaniTests` so `swift test` cannot exercise the runtime).
- **Pre-condition:** HEAD descendant of commit `2a281a9` (`close: phase-u2b-1b-5-wkwebsitedatastore-egress-proxy-wiring` introducing `proxyConfigurations` in BrowserPaneRunner.swift); `swift build --product SenkaniApp` and `swift build --product senkani` green; no running SenkaniApp / EgressProxy daemon (Setup clears any stale state); ports `$EGRESS_PORT` (default `18080`) and `$FIXTURE_PORT` (default `8765`) free (override via env if busy); `jq`, `python3`, `lsof` on `$PATH`. Setup writes a TIGHT base egress policy at `~/.senkani/egress-policy.json` (suffix-allow `127.0.0.1` for all four PaneModes — `research` / `write` / `redteam` / `general`); existing policy backed up at `~/.senkani/egress-policy.json.walk-backup` and restored in Teardown.
- **Validates:**
  - **(a) Daemon up + listening (Step 1)** — `egress: listening on :$EGRESS_PORT` in daemon log; `lsof -iTCP:$EGRESS_PORT -sTCP:LISTEN` non-empty; `~/.senkani/egress.port` matches.
  - **(b) Allowlist case (Step 3)** — MCP `validate_browser` (bare wire name — `senkani_` prefix is a Claude-Code UI-display convention, not on the wire; `ToolRegistry.byName` is exact-match per `Sources/MCP/ToolRegistry.swift:388-390`) `tools/call` with `dispatch=headless` + `egress_proxy_url=http://127.0.0.1:$EGRESS_PORT` + `target_url=http://127.0.0.1:$FIXTURE_PORT/` returns `result_status: pass`; daemon decisions log shows ≥1 `allow` row with `host=127.0.0.1` and `rule=walk_allow_localhost`. The MCP transport is JSON-RPC stdio against `.build/{release,debug}/SenkaniApp --mcp-server` (the ONLY binary that registers `BrowserPaneRunnerFactory`; the `senkani-mcp` standalone binary returns `headless_not_yet_implemented` per `Sources/Core/Validation/BrowserDispatchRegistry.swift:63-68`). The corrected `mcp-driver.py` heredoc auto-injects `SENKANI_PANE_ID` (synthesized UUID per run) into the spawned subprocess env, satisfying `MCPServerRunner.run()`'s access gate at `Sources/MCP/MCPMain.swift:22` — without that injection the server exits 0 silently and the driver records `{"error": "no_response_within_60s"}`. Driver script committed verbatim as `mcp-driver.py` in the run dir.
  - **(c) Override-file cleanup (Step 4)** — `diff baseline-override-files.txt override-files-post-step3.txt` exits 0; no `$TMPDIR/senkani-egress-override-*.json` files survive (the `defer` block at `SenkaniApp/Services/BrowserPaneRunner.swift:205-208` removes them on every return path).
  - **(d) Out-of-allowlist case (Step 5)** — `target_url=https://example.com/` returns `result_status: fail` + advisory `page_load_failed`; daemon decisions log shows ≥1 `deny` row with `host=example.com` and `rule=default-deny` (matches `Sources/Core/EgressProxy/EgressRuleEngine.swift:107`).
  - **(e) Load-bearing daemon-down falsifier (Step 6)** — daemon stopped, port confirmed free, then driver re-run against the allowlist fixture: response `result_status: fail` + advisory `page_load_failed`. Without `WKWebsiteDataStore.proxyConfigurations = [proxy]` actually being honored by WebKit, WKWebView would have fetched `127.0.0.1:$FIXTURE_PORT` directly (it's a real listening port) and Step 6 would falsely PASS. **A pass here is a P0 finding (file `process-gap-browserpanerunner-proxy-config-not-applied-<RUN_TS>`) — do NOT close the walk PASS.**
  - **(f) Daemon-restart symmetry (Step 7)** — daemon restarted; SessionDatabase decisions from Steps 3 + 5 survive (durable rows); `final-status.txt` includes both rows.
- **Audit-accepted risks (Bach / Russell / Sutton groom round 2026-05-22):**
  - Bach — proxy-config-application-path falsifiability: Step 6 (daemon-down → `page_load_failed`) is the load-bearing falsifier; the structural test only proves source-shape presence. Documented in body + failure-modes.
  - Russell — override-policy-file-applied-or-not is OBSERVATION-ONLY for WKWebView today: the file is written-and-discarded as a no-op (the override pickup path lives on the subprocess Chromium runner via `SENKANI_EGRESS_POLICY_OVERRIDE`). The walk verifies create/cleanup but NOT daemon-side application — the BASE policy at `~/.senkani/egress-policy.json` is what enforces; Setup writes the tight base policy precisely so Step 5's deny case tests the base policy, not the per-target override. Russell-accepted; failure-mode row warns the operator not to chase a non-existent override-file-application path.
  - Sutton — bundle-vs-unbundled distinction: this walk uses `.build/{release,debug}/SenkaniApp` directly (no `tools/soak/runner/SenkaniApp.app` bundle needed — `--mcp-server` mode runs unbundled). Documented in Cowork hints so future grooming rounds don't copy the t6 bundle-rebuild path by reflex.
- **Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings to named follow-up filings before retry:** `process-gap-browserpanerunner-factory-not-registered-<RUN_TS>` (Step 3 returns `headless_not_yet_implemented` — binary built without U.2b-1b-6's `main.swift:19` factory wire); `process-gap-browserpanerunner-runtime-crash-<RUN_TS>` (Step 3 hangs > 60 s with WKWebView crash in stderr); `process-gap-browserpanerunner-override-file-leak-<RUN_TS>` (Step 4 surviving files); `process-gap-egress-default-deny-regression-<RUN_TS>` (Step 5 passes despite tight policy); **`process-gap-browserpanerunner-proxy-config-not-applied-<RUN_TS>` (Step 6 passes — P0 wiring-bypass)**. Teardown is mandatory even on failure (stops daemons, kills fixture server, removes fixture dir, restores `~/.senkani/egress-policy.json`, sweeps lingering override files).
- Groomed 2026-05-22 by `senkani-autonomous`; awaits operator/Cowork execution → flip `status: manual_ready` → `status: done` + paste evidence into `## Execution evidence` → run `/senkani-autonomous` so the next round's close-mode sweep finalizes.

### t6-notification-cowork-banner-walk-2026-05-21 — verify a UN banner actually appears + the `~/.senkani/notifications.json` opt-out suppresses it, end-to-end on a real macOS machine 2026-05-22

- **Item:** [`spec/autonomous/backlog/t6-notification-cowork-banner-walk-2026-05-21.md`](../../spec/autonomous/backlog/t6-notification-cowork-banner-walk-2026-05-21.md)
- **Parent (production wiring shipped):** [`spec/autonomous/completed/2026/2026-05-21-t6-notification-production-hookup-missing-2026-05-17.md`](../../spec/autonomous/completed/2026/2026-05-21-t6-notification-production-hookup-missing-2026-05-17.md)
- **Exec mode:** **either, but split** — Setup + Steps 1, 3, 8-11, 13-14 + Teardown are Cowork-runnable shell end-to-end (`swift build` / `walk rebuild-bundle`, `pgrep`, `tccutil`, `defaults read`, `jq`, `cat` heredoc, `osascript`, `log show`); Steps 2 (TCC dialog click), 4-5 (Claude pane + savings observation + banner screenshot), 7 (Notification Center group row screenshot), 12 (re-trigger + no-banner observation) are `gui (cowork)` driven via `mcp__computer-use__screenshot` / `mcp__computer-use__zoom`. No `gui (human)` first-grants required beyond the Step 2 TCC dialog (which is *part* of the acceptance, not a side-grant — Cowork drives it).
- **Time estimate:** **~25-35 min operator-supervised** (~8-10 min shell + ~15-25 min GUI depending on Claude session response time + ~2 min teardown).
- **What it proves:** the SenkaniApp production wiring shipped 2026-05-21 (`NotificationBootstrap.bootstrap()` + `NotificationBootstrap.requestAuthorizationIfNeeded()` from `SenkaniGUI.init()`; `UNNotifierBridge` post path; `OnboardingMilestoneStore.record(.firstNonzeroSavings)` firing `NotifyEvent.notifyDone(toolName: "onboarding", summary: "Save your first tokens")`) actually delivers a `UNUserNotificationCenter` banner on a real macOS machine, AND that `~/.senkani/notifications.json` opt-out is the load-bearing config-drives-the-router contract. Closes parent acceptance bullets 7 + 11 with screenshot + log evidence; back-fills `release-v0-3-0-surface-pass` Step 2 row 2 (`MacOSLocalSink + NotificationRouter`) from SPLIT-FAIL to PASS.
- **Pre-condition:** HEAD descendant of the parent close commit (introduces `SenkaniApp/Services/NotificationBootstrap.swift`); `swift build --product SenkaniApp` green; no running SenkaniApp (2026-05-05 process standard); `~/.senkani/notifications.json` and `~/.senkani/onboarding/milestones.json` absent (Setup deletes them; `tccutil reset Notifications dev.senkani.app` clears the prior grant so Step 2's prompt fires deterministically); `jq` on `$PATH` (Setup checks). Bundle path: `tools/soak/runner/SenkaniApp.app` refreshed via `senkani walk rebuild-bundle <bundle>` (auto-rebuild) or `tools/soak/runner/08-make-app-bundle.command` from scratch.
- **Validates:** (a) Step 2 TCC prompt appears with verbatim title `"Senkani" Would Like to Send You Notifications`; operator clicks Allow; `defaults read com.apple.ncprefs apps | grep dev.senkani.app` confirms the grant landed (Step 3). (b) Step 5 banner appears with EXACT copy — title `Senkani — done` (em dash), subtitle `onboarding`, body `Save your first tokens` — verified against `Sources/Core/MacOSLocalSink.swift:97-98` + `Sources/Core/OnboardingMilestone.swift:89-91`. (c) Notification Center persisted group row survives banner auto-dismiss (Step 7). (d) `~/.senkani/onboarding/milestones.json` records `firstNonzeroSavings` ISO8601 timestamp (Step 6). (e) **Load-bearing opt-out cross-check (Step 12):** after Step 8 clean quit + Step 9 `{"macos_local": {"events": ["notify_failure", "schedule_end"]}}` opt-out write + Step 10 milestones reset + Step 11 relaunch, a second `firstNonzeroSavings` trigger produces NO banner AND NO new Notification Center group row, BUT the `stdout` sink HAS logged the event (proves the producer + router fired and `macos_local` correctly suppressed — the only way to refute "the event never fired" as the no-banner explanation). (f) Step 13 fresh ISO8601 timestamp on `firstNonzeroSavings` newer than Step 6 proves the milestone re-fired (closes the loophole). (g) Step 14 one-line cross-check note records the surface-pass-Step-2-row-2 SPLIT-FAIL→PASS back-fill.
- **Audit-accepted risks (Norman / Sutherland / Kleppmann groom round 2026-05-22):**
  - Norman — savings-trigger non-determinism on Step 4 (`firstNonzeroSavings` needs Filter/Cache to report `savedTokens > 0` on a real Claude session; same risk surfaced 2026-05-11 on the milestones-4-7 walk — retry path documented in failure-modes; 3-retry threshold → DEFECT-OUTSIDE-CRITERIA filing).
  - Sutherland — `tccutil reset Notifications` macOS-version cache fall-through (rare; failure-modes row tells operator to log out / log in if TCC dialog never appears; the `|| true` in Setup tolerates the rare exit-non-zero).
  - Kleppmann — config-loaded-at-boot (not hot-reloaded); Step 8 (quit) + Step 11 (relaunch) load-bearing for opt-out test (without them the live router has stale subscription from previous boot). Failure-modes row also names this for the operator.
- **Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings to named follow-up filings before retry:** `t6-banner-walk-savings-trigger-non-deterministic-<RUN_TS>` (Step 4 fails after 3 retries — Filter pipeline not producing non-zero savings on fresh Claude sessions); `t6-notification-config-not-applied-<RUN_TS>` (Step 12 fails — banner appears despite opt-out config); `t6-banner-walk-tcc-cache-fall-through-<RUN_TS>` (Step 2 fails AND log-out / log-in doesn't clear it). Teardown is mandatory even on failure (restores `~/.senkani/notifications.json` + `~/.senkani/onboarding/milestones.json` to default).
- Groomed 2026-05-22 by `senkani-autonomous`; awaits operator/Cowork execution → flip `status: manual_ready` → `status: done` + paste evidence into `## Execution evidence` → run `/senkani-autonomous` so the next round's close-mode sweep finalizes (and flips surface-pass Step 2 row 2 commentary on close-mode doc-sync).

### process-gap-scope-groom-meaty-size-envelope-check-2026-05-19 — wire envelope-size helper into SKILL.md scope-groom phase 4 + step 6.5 (idempotent shell-mode hand-edit) 2026-05-22

- **Item:** [`spec/autonomous/backlog/process-gap-scope-groom-meaty-size-envelope-check-2026-05-19.md`](../../spec/autonomous/backlog/process-gap-scope-groom-meaty-size-envelope-check-2026-05-19.md)
- **Exec mode:** **cowork or operator — either** (fully shell-driven via Bash + a single ~50-line python heredoc; no GUI editor required). All commands are read-only against `tools/autonomous/` and read-write against `~/.claude/skills/senkani-autonomous/SKILL.md` (operator-home file; no TCC gate, no sudo, no permission prompts expected).
- **Time estimate:** ~5 min hands-on; ~10 min including evidence paste back into the per-item file's new `## Execution evidence` section.
- **What it proves:** the already-shipped `tools/autonomous/check_envelope_size.py` helper (8 unit tests green; `MEATY_SIZE_TOKENS = ("meaty", "large")` + `BULLET_THRESHOLD = 5`; canonical 3-option `suggested_question` rendered ready for `AskUserQuestion`; PROCESS.md `## Scope-groom envelope-size check` section) wires into `~/.claude/skills/senkani-autonomous/SKILL.md` scope-groom phase 4 (new "Envelope-size check" bullet at end of the Question battery list) + new step 6.5 ("Envelope-size pre-call check" between step 5 "Audit the questions" and step 6 "Run the interview"). End-to-end verification: helper tests green BEFORE AND AFTER the SKILL.md edit; helper fires `should_fire: true` + `size: meaty` + `bullet_count: 8` on the originating `phase-t3-wasm-sandbox` overflow item; helper fires `should_fire: true` + `size: small` + `bullet_count: 10` on this very item post-grooming via the bullet-count-only branch (`reasons[].kind == "bullet_count"`, NOT `size`); both sentinel strings (`Envelope-size check` for the phase-4 bullet, `Envelope-size pre-call check` for step 6.5) absent before the edit + present after; `diff $SNAPSHOT $SKILL_PATH` is insertion-only (no deletions). The insertion script is idempotent (`no-op: both sentinels already present`) and partial-state-refusing (`FAIL: partial-wire state` if one sentinel was inserted manually but not the other — operator reconciles).
- **Pre-condition:** repo on `main`; helper + tests + PROCESS.md section already shipped (autonomous portion landed 2026-05-21); SKILL.md writable; SKILL.md NOT yet contains either sentinel (both greps return 0); SKILL.md's scope-groom phase 4 still ends with the anchor pair `'captured?") — free-text where useful.\n'` + `'\n   Aggressive use of multi-choice is preferred — operator chooses\n'`; SKILL.md's scope-groom phase 5→6 boundary still anchored by `'that would block the build round? Are options exhaustive?\n'` + `'6. **Run the interview** — call \`AskUserQuestion\` with the audited\n'` (both anchor pairs verified during groom-round dry-read 2026-05-22 — each unique, count=1).
- **Verdict semantics:** 10-bullet acceptance checklist must all flip ✅ for PASS. The insertion script is anchor-based + sentinel-guarded; if either anchor drifts (future SKILL.md re-wording) the script exits non-zero (`FAIL: phase-4 anchor not found` exit 2; `FAIL: step-6.5 anchor not found in post-phase-4-insert text` exit 2) and the operator falls back to manual paste against the canonical text preserved in the per-item file's `## Build abort note 2026-05-21` section (with the 2026-05-22 groom-round `manual + decomposable: true` correction for option (b) — see the `### Groom-round addendum 2026-05-22 — canonical-text update` paragraph in `## Pre-grooming notes`). Any acceptance failure → leave `status: manual_ready`, restore SKILL.md from the snapshot path printed by Setup, append findings to `## Pre-grooming notes` (NOT the immutable audit-trail sections), and either retry after patching the failure-mode root cause or file a new backlog item under `process-gap-envelope-wire-script-non-idempotent-<date>` / `process-gap-envelope-helper-regression-<date>` per the failure-modes table.

### process-gap-build-round-categorical-action-vetting-2026-05-07 — wire categorical-block helper into SKILL.md scope-groom phase (idempotent shell-mode hand-edit) 2026-05-22

- **Item:** [`spec/autonomous/backlog/process-gap-build-round-categorical-action-vetting-2026-05-07.md`](../../spec/autonomous/backlog/process-gap-build-round-categorical-action-vetting-2026-05-07.md)
- **Exec mode:** **cowork** (or operator — fully shell-driven via Bash + a 100-line python heredoc; no GUI editor required). Operator-machine first-grant of macOS `Files & Folders` may surface ONCE when python3 first writes to `~/.claude/` from a fresh terminal session.
- **Time estimate:** ~10 min shell-only; ~15 min if operator prefers manual editor paste for step 4.
- **What it proves:** the already-shipped `tools/autonomous/check_categorical_block.py` helper (8 unit tests green; 8 default patterns; manifest-merge contract; PROCESS.md scope-groom-categorical-block section) wires into `~/.claude/skills/senkani-autonomous/SKILL.md` scope-groom phase as steps 7.5 (categorical-block check, defense-in-depth) + 7.6 (explicit-confirmation override via `AskUserQuestion`). The wiring is verified end-to-end: helper tests green before AND after the SKILL.md edit; helper detects ≥ 7 categorical-block matches (pattern IDs {1, 2, 3, 4, 6, 7}) on the per-item spec file before AND after the edit; sentinel strings `Categorical-block check (defense-in-depth)` + `Explicit-confirmation override` present in SKILL.md post-edit; diff between snapshot and edited SKILL.md is insertion-only (no deletions outside the anchor site); second invocation of the insertion script is a no-op (idempotency).
- **Pre-condition:** repo on `main`; helper + tests + manifest block + PROCESS.md section already shipped (autonomous portion landed 2026-05-21); SKILL.md writable; SKILL.md NOT yet contains the `Categorical-block check (defense-in-depth)` sentinel (grep returns 0); SKILL.md's scope-groom phase 7 still ends with the anchor text `captured from the operator's answer.` (verified during groom-round dry-read 2026-05-22 — anchor at SKILL.md:958).
- **Verdict semantics:** 10-bullet acceptance checklist must all flip ✅ for PASS. The insertion script is anchor-based + sentinel-guarded; if the anchor drifts (future SKILL.md re-wording) the script exits non-zero with `scope-groom-phase anchor not found` and the operator falls back to manual paste against the canonical text preserved in the per-item file's `## Build abort note 2026-05-21` section. Any acceptance failure → leave `status: manual_ready`, restore SKILL.md from the snapshot path printed by Setup, append findings to `## Pre-grooming notes` (NOT the immutable audit-trail sections), and either retry after patching the failure-mode root cause or file a new backlog item under `process-gap-categorical-block-wire-script-non-idempotent-<date>` / `process-gap-categorical-block-helper-regression-<date>` per the failure-modes table.

### phase-u4b-2-promotion-gate-gui-surfaces — TrustFlagsView mode toggle + per-flag Override (hybrid implement+verify Cowork walk) 2026-05-22

- **Item:** [`spec/autonomous/backlog/phase-u4b-2-promotion-gate-gui-surfaces.md`](../../spec/autonomous/backlog/phase-u4b-2-promotion-gate-gui-surfaces.md)
- **Exec mode:** **cowork** (Cowork drives Xcode/editor for the two SwiftUI edits + new `SenkaniApp/Services/TrustGateService.swift` file, then runs the GUI verification walk; final VoiceOver focus-order check is `gui (human)` operator-only)
- **Time estimate:** ~50-70 min wall-clock (Cowork SwiftUI editing 15-25 min; build + GUI verification 20-30 min; operator a11y check 3 min); hard cap at 90 min wall-clock — if exceeded, abort + retry from fresh state per the per-item file's failure-modes section
- **What it proves:** the U.4b-2 GUI surfaces materialize on top of U.4b-1's already-shipped runtime contract: header mode-toggle pill reflects current `TrustMode` and surfaces gate-rejection text inline without writing the chain on a probe miss; confirmation sheet on the accept path writes the `promotion` chain row + persists `~/.senkani/trust.json`; per-row "Override" button appears only in `.blocking` mode and writes a `trust_audits.override` row keyed `"flag:<id>"` (advisory in this round — HookRouter doesn't honor flag-keyed overrides yet); state durable across an app relaunch.
- **Pre-condition:** clean working tree on `main`; freshly built `senkani` CLI; `~/.senkani/trust.json` is backed up + reset to a known starting point in Setup; Cowork primitives (`mcp__computer-use__screenshot`/zoom/click/move/type) available in the Desktop session; sqlite3 reachable for the trust_audits schema confirmation step.
- **Verdict semantics:** 11-bullet acceptance checklist must all flip ✅ for PASS. Any acceptance failure → leave `status: manual_ready`, append findings to a `## Walk findings <date>` section, file defects-outside-criteria as new backlog items per the loop's mandatory-follow-up-filing rule, retry after patch. On PASS the operator commits the Cowork-applied SwiftUI edits in a separate commit BEFORE flipping the item to `done` (convention `feat: U.4b-2 — promotion-gate GUI surfaces (mode toggle + per-flag override)`).

### search-web-soft-block-real-network-rewalk — real-DDG rotation recovery on soft-blocked operator IP 2026-05-21

- **Item:** [`spec/autonomous/backlog/search-web-soft-block-real-network-rewalk-2026-05-21.md`](../../spec/autonomous/backlog/search-web-soft-block-real-network-rewalk-2026-05-21.md)
- **Exec mode:** **either** (purely shell-driven via `python3` heredoc piped to `.build/release/senkani-mcp` over stdio; Cowork can paste each heredoc into Terminal; no GUI hands needed)
- **Time estimate:** ~15-30 min wall-clock (PATH-PRE-SOFTBLOCKED 3-5 min; PATH-INDUCE 5-15 min; PATH-CANNOT-INDUCE 8-12 min); ~5-10 min operator-supervised attention. Hard cap: 30-min target / 60-min absolute. Bounded inducer caps at ≤30 queries / 60 s wall-clock so DDG does not multi-hour-ban the operator's IP.
- **What it proves:** the 2026-05-21 build round (`search-web-ddg-soft-block-resilience-2026-05-16`) shipped the autonomous portion against injected fixtures — 10 swift-testing cases green for region rotation, cool-down ledger (0600), structured `allRegionsCooling` payload, 2-attempt HTTP cap. This walk produces the missing operator-side evidence: a real-network `wt-wt`-cooling-then-`us-en`-recovery transcript captured against `lite.duckduckgo.com` from the operator's actual IP, the ledger artifact, and timing observations within the 60-second SLA.
- **Pre-condition:** `.build/release/senkani-mcp` built (or debug fallback), `lite.duckduckgo.com` reachable, `python3` available. The walk's evidence directory lands under `tools/soak/evidence/search-web-soft-block-rewalk/walk-<TS>/`. The teardown explicitly clears the ledger so the 30-min default cool-down doesn't ghost subsequent `senkani_search_web` calls.
- **Verdict semantics:** four enumerated states recorded in `verdict.txt` — `PASS` flips item to `done`; `INCOMPLETE-PATH-CANNOT-INDUCE` keeps `manual_ready` and the operator re-attempts on a future day (DDG-soft-block state is uncontrolled); `FAIL-ROTATION-DID-NOT-RECOVER` opens a new backlog item against the rotation regression with evidence linked.

### ci-chunk-other-sigtrap-retry-exhaust — matrix-CI rewalk for chunk[other] SIGTRAP recurrence 2026-05-21

- **Item:** [`spec/autonomous/backlog/ci-chunk-other-sigtrap-retry-exhaust-2026-05-08.md`](../../spec/autonomous/backlog/ci-chunk-other-sigtrap-retry-exhaust-2026-05-08.md)
- **Exec mode:** Cowork or operator (entirely shell-driven via `gh` CLI; no GUI; first `gh auth status` may need operator hands)
- **Time estimate:** ~30-60 minutes operator-supervised across the walk; 1 day to 2 weeks elapsed (cadence-bound by `main`-branch push velocity)
- **What it proves:** whether the matrix-CI fan-out shipped 2026-05-18 (`.github/workflows/test.yml` 8-chunk matrix) incidentally closed the chunk[other] SIGTRAP retry-exhaust observed in 3 pre-matrix reproductions (2026-05-08 PR-CI 25554316180, main-CI 25554480209, PR-CI 25572249946). The validation accumulates 5 consecutive matrix-CI runs of chunk[other] against `main` HEAD and branches: 5/5 green → parent acceptance #2 closes via the matrix-fan-out reference; any SIGTRAP recurrence → file `ci-chunk-other-sub-split-<chunks>-2026-05-21` per parent acceptance #3.
- **Pre-condition:** local main is 140 commits ahead of origin/main as of 2026-05-21; step 2 of the plan pushes those commits to trigger the first matrix-CI run on `main` (operator-decision push — 140 commits is large; operator may prefer to split into smaller pushes, but the rolling-5-window admits incremental accumulation either way).


> The plan body lives in the per-item file; this section is a
> cadence-friendly index. Operator (or Cowork in Claude Desktop)
> picks one, runs it, follows the `## Operator contract` in the
> linked file, and lets the next `/senkani-autonomous` close-mode
> sweep finalize.

> **Process standard for walk-runner bundle staleness (added 2026-05-14).**
> Walk runners that wrap the SenkaniApp binary into an `.app` bundle
> under `tools/soak/runner/` are now guarded against silent stale-walk
> hazards by `senkani doctor` check #20 and the shared rebuild helper
> exposed as `senkani walk rebuild-bundle <bundle>` (shipped
> 2026-05-14 via
> [`onboarding-pass-stale-bundle-hazard-2026-05-14`](../../spec/autonomous/completed/2026/2026-05-14-onboarding-pass-stale-bundle-hazard-2026-05-14.md)).
> Onboarding-pass precheck runners (e.g.
> `tools/soak/runner/rewalk-2026-05-13-01-precheck.command`) invoke the
> helper at pre-flight; the operator no longer needs to manually
> compare bundle binary mtime against `main` HEAD or perform the
> `swift build` / `cp` / `codesign` / `lsregister` dance by hand.
> `senkani doctor` auto-rebuilds on detected staleness unless
> `--no-rebuild-stale-bundle` is passed. Reason: 2026-05-14
> onboarding-pass walk Finding #H — the wrapped bundle the
> 2026-05-11 walk session was driving silently fell behind `main`
> by a critical-AC commit; only the walk's plan-level check
> caught it.

> **Process standard for uninstall test plans (added 2026-05-05).**
> Every groomed uninstall test plan (v3 amendment, v0.4.0 release
> pass, or any future variant) MUST include a
> `no-running-senkani` pre-condition probe in its `## Pre-conditions`,
> `## Setup`, and `## Failure modes` sections. Skeleton lives in
> `spec/autonomous/completed/2026/<YYYY-MM-DD>-uninstall-test-plan-prerunning-process-precondition-…`
> (closed 2026-05-05) and is mirrored in
> `spec/autonomous/backlog/uninstall-rewalk-step8-modelmetadatacache.md`'s
> `## Pre-grooming notes`. Reason: 2026-05-03 v2 walk surfaced a
> still-running SenkaniApp re-seeding `~/.senkani/workspace.json`
> mid-test, contaminating the audit trail. The probe halts the test
> at preconditions before any state mutation.

- **phase-v9b-filter-ui — visual verification of the ArtifactGalleryView toolbar filter UI (source-pane chips + tag chips with autocomplete + version range + since-date + 250 ms debounce + clear button)** ([per-item file at close](../../spec/autonomous/completed/2026/2026-05-21-phase-v9b-filter-ui-v-9b-2-artifact-gallery-filter-ui.md)). Exec mode: **either** — every filter surface (chip toggles, text input, autocomplete buttons, version min/max fields, since toggle + date picker, Clear button) is a pure SwiftUI control drivable by Cowork via `mcp__computer-use__screenshot` / `mcp__computer-use__zoom`; observed-tag autocomplete validates against the operator's actual `~/.senkani/artifacts/*.tags` sidecars + paneDiary + SprintReview fixtures so the autocomplete suggestions are real, not synthetic. Time estimate: **~6-10 min operator-supervised** (1 min open ArtifactGallery pane + populate ~5 fixture artifacts spanning paneDiary / sprintReview / filesystem with at least 3 distinct tags and versions 1-4 across the rows / 1 min verify default state shows all 3 source-pane chips lit + count matches total artifact rows / 1 min click paneDiary chip — verify it dims to ~35% opacity + within 250 ms the list shrinks to non-paneDiary rows only + Clear button surfaces / 1-2 min type partial tag into search field — verify top-3 autocomplete buttons appear matching observed tags + click one → chip appears + list filters within 250 ms / click chip × → chip removed + list restores / 1 min enter `2` in version-min + `3` in version-max + Tab → list shrinks to v2/v3 rows only / 1 min toggle since checkbox → DatePicker appears + pick a date midway through fixture timestamps → list cuts older rows / 1 min press Clear → all fields return to default + list restores to full set). Pre-condition: HEAD includes V.9b-2 close commit; SenkaniApp bundle rebuilt + relaunched (`senkani walk rebuild-bundle …` if using the runner bundle); no running stale SenkaniApp per 2026-05-05 process standard; ~5 fixture artifacts seeded across all three source panes. Validates: (a) toolbar form renders above V.9b-1's list column at sensible row heights without breaking the split-pane proportions; (b) chip-state mutations apply within the 250 ms debounce window on a real workspace (not just synthetic test fixtures); (c) tag autocomplete observes the actual `list` result — typing a substring shows real tags from the current rows, not stale or global suggestions; (d) version min/max parse non-negative integers correctly and reject empty/whitespace strings without crashing; (e) since-toggle gate correctly suppresses the constraint when off; (f) Clear button surfaces only when filter ≠ unconstrained AND resets every dimension including the local `@State` mirrors (tag-input text, version min/max text, since-toggle) — not just the model. Audit-accepted risks (Jobs / Norman / Zhuo build round 2026-05-21): deselecting every source-pane chip collapses to unconstrained (model emits nil for empty Set; ArtifactFilter treats nil as match-all) — spec documents this contract; surfacing it as a snap-back in the view defers to V.9c+ if operator preference emerges during real-machine use. Filed 2026-05-21 by `senkani-autonomous` per item's `manual_validation_needed` affects tag; awaits operator/Cowork execution → no `status: done` flip needed (the V.9b-2 build round already closed) — this entry is a real-machine soak gate, not a close gate.

- **phase-v9b-gallery-view — visual verification of the ArtifactGalleryView pane (split-pane render + click-nav routing + lineage drill-in + reveal-sheet confirmation copy)** ([per-item file at close](../../spec/autonomous/completed/2026/2026-05-21-phase-v9b-gallery-view-v-9b-artifactgalleryview-pane-click-to-navigate.md)). Exec mode: **either** — split-pane rendering + click selection + reveal-sheet copy are pure SwiftUI surfaces drivable end-to-end by Cowork via `mcp__computer-use__screenshot` / `mcp__computer-use__zoom`; route execution (focus pane diary / focus SprintReviewPane / `NSWorkspace.activateFileViewerSelecting` for filesystem) is observable in the live window. Time estimate: **~8-12 min operator-supervised** (1 min add pane via AddPaneSheet → "Artifact Gallery" card + verify pane renders at `columnWidth=720` + empty-state copy "No artifacts yet…" / 2-3 min populate `~/.senkani/artifacts/notes.v1.md`, `~/.senkani/artifacts/notes.v2.md`, `~/.senkani/artifacts/notes.v3.md` + sidecar `notes.v3.tags` with `alpha\nbeta` + observe gallery shows 3 rows with `file` badge / 2 min single-click row selects + detail pane renders + Lineage (3) block shows v1 v2 v3 + clicking v1 row switches detail / 2 min double-click filesystem row + Finder reveal fires / 2-3 min write a paneDiary file at `~/.senkani/diaries/<projectSlug>/terminal.md` containing `sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA` + observe 🔒 in list + detail + click "Reveal body" + verify confirmation-sheet copy reads VERBATIM `Reveal redacted body? Source: paneDiary. Redaction marker hits: 1. This writes an artifact.secret.allow row to your audit chain.` + click `Reveal and audit` + body renders + `sqlite3 ~/Library/Application\ Support/Senkani/senkani.db "SELECT feature,command FROM token_events WHERE feature='artifact.secret.allow' ORDER BY id DESC LIMIT 1;"` confirms chain row written with `ANTHROPIC_API_KEY` pattern name in `hit_pattern_names` AND `sk-ant-…` absent from the row). Pre-condition: HEAD includes V.9a + V.9b-1 close commits; SenkaniApp bundle rebuilt + relaunched (`senkani walk rebuild-bundle …` if using the runner bundle); no running stale SenkaniApp per 2026-05-05 process standard. Validates: (a) `case artifactGallery` registers across all 4 sites (PaneModel, PaneContainerView, AddPaneSheet, PaneGalleryBuilder) on the operator's real macOS render path — unit tests cover the Core router but the SwiftUI rendering is the surface that ships; (b) `columnWidth=720` holds on a real workspace alongside other panes; (c) empty-state copy renders verbatim when `~/.senkani/artifacts/` is empty; (d) sidecar `.tags` file extends the tag set as expected on real APFS; (e) 🔒 icon + reveal-sheet copy + audit-row write hold end-to-end against `SessionDatabase.shared` (the unit tests use a temp DB); (f) `NSWorkspace.activateFileViewerSelecting` opens Finder at the artifact path; (g) lineage drill-in re-renders detail against the predecessor record. Audit-accepted risks (Jobs/Norman/Zhuo build round 2026-05-21): SprintReviewPane scroll-to-row binding NOT yet wired (V.9b-1 ships the focus path only); operator notes "scroll to row" is a follow-up if dogfooding shows the focus alone is insufficient — file as `phase-v9b-followup-sprint-review-scroll-target-binding` at that point. Filed 2026-05-21 by `senkani-autonomous` per item's `manual_validation_needed` affects tag; awaits operator/Cowork execution → no `status: done` flip needed (the parent V.9b-1 already closed via this build round) — this entry is a real-machine soak gate, not a close gate.

- **phase-t2c-2-redteam-pane-and-engagement-cli — real-machine validation of the redteam-pane sensitivity-drop + `senkani engagement` lifecycle (CLI start/end/list under operator's actual Keychain T.4 derivation path)** ([per-item file](../../spec/autonomous/completed/2026/2026-05-20-phase-t2c-2-redteam-pane-and-engagement-cli.md)). Exec mode: **human** (TCC + Keychain first-grants on first `senkani engagement start` against `CredentialVault.read(key: "vault-key", scope: "engagement-<id>")` — the operator's login keychain may prompt for "Always Allow" the first time the senkani binary requests access; subsequent runs are no-op until the keychain is locked). Time estimate: **~5-8 min operator-supervised** end-to-end (1 min `senkani engagement start operator-walk-<RUN_TS>` + observe `key_source=credential_vault` in stdout / verify vault file at `~/.senkani/surrogates/<name>.sqlite` mode 0600 / 1 min `senkani engagement list` and confirm `name | status | vault_bytes | key_source` columns render with `open` status + `credential_vault` source / 1 min `senkani engagement end <name>` and confirm `closed_at <ISO>` stdout + re-`list` shows `closed` status / 1 min sqlite3 dump of `surrogate_writes` rows by running `senkani exec --pane redteam --output 'Voldemort sends regards.'` against a fresh engagement then `sqlite3 ~/Library/Application\ Support/Senkani/senkani.db "SELECT engagement_id, surrogate_id, category, datetime(at,'unixepoch') FROM surrogate_writes ORDER BY id DESC LIMIT 10;"` / 1-2 min `senkani doctor` to confirm `surrogate_writes` appears in the audit-chain summary + chain verifies OK). Pre-condition: HEAD includes T.2c-2 close commit; `~/.senkani/surrogates/` either fresh or contains only the operator's existing engagements; T.4 CredentialVault `engagement-<id>` scope shape is reserved per the T.4 documentation. Validates: (a) `key_source=credential_vault` not `fallback_random` (proves Keychain hard-preferred path works under operator's actual TCC posture, not just the InMemoryKeychainStore test path); (b) vault file mode 0600 holds on the real `~/.senkani/surrogates/` filesystem (not `/tmp` test fixture); (c) `senkani engagement end` is durable across CLI process restarts — re-running `senkani engagement list` after `end` still reads `closed`; (d) `surrogate_writes` chain rows materialize on real `~/Library/Application Support/Senkani/senkani.db` with `original_value` absent from the row schema (sqlite3 `SELECT * FROM surrogate_writes` columns are `id, engagement_id, surrogate_id, category, at, prev_hash, entry_hash, chain_anchor_id` only); (e) `senkani doctor` chain audit lists `surrogate_writes` alongside the other 11 participants + `--verify-chain` returns OK on a chain containing real surrogate-write rows. Audit-accepted risks (Cavoukian/Schneier groom — to be re-confirmed during walk): operator may not have a `redteam`-mode pane wired into a HookRouter-managed subprocess yet, so step (e) may need to use a direct unit-test-like proxy invocation if the production redteam-pane wiring doesn't surface from a CLI flag on `senkani exec` (file finding if missing; the chain-row write path is exercised by AnonymizationProxy's auditSink whether the redteam pane drives it or a direct test does). Filed 2026-05-20 by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize. Companion T.2c real-machine validation under operator's actual Keychain (T.4 derivation path) per the item's manual_validation_needed `affects:` tag.

- **senkani-app-emfile-crash-manual-validation-2026-05-15 — real-machine validation that the EMFILE-crash fix (raise RLIMIT_NOFILE at startup + in-process git-blob SHA1) holds across the 200×10 stress harness + "Open a tracked shell" pane-launch that originally took the app down on 2026-05-15 07:43 -0400** ([groomed plan](../../spec/autonomous/backlog/senkani-app-emfile-crash-manual-validation-2026-05-15.md), [closing build round](../../spec/autonomous/completed/2026/2026-05-15-senkani-app-emfile-crash-during-pane-launch.md), [parent gate](../../spec/autonomous/backlog/claude-session-watcher-cancel-handler-race-fix-2026-05-14.md)). Exec mode: **either, but split** — Setup + Steps 1, 4-6, 9-12 + Teardown are Cowork-runnable shell end-to-end (`swift build`, `walk rebuild-bundle`, `pkill`, `lsof`, the 200×10 probe harness, sqlite3 row-count query, `log show` rotation-event grep, sentinel cleanup); Steps 2, 3, 7, 8 are `gui (cowork)` driven via `mcp__computer-use__screenshot` / `mcp__computer-use__zoom` (bundle launch confirmation, senkani project switch, "Open a tracked shell" card click, post-pane-launch terminal visibility). Time estimate: **~10 min operator-supervised**, ~3-4 min shell + ~3-4 min GUI + setup/teardown. Pre-condition: working tree on `main`, HEAD includes commit `80a2494` or a descendant (`senkani-app-emfile-crash-during-pane-launch-2026-05-15`), `.build/release/senkani --version` exits 0, `tools/soak/runner/SenkaniApp.app` present, encoded Claude project dir `~/.claude/projects/-Users-clank-Desktop-projects-senkani` exists, no running SenkaniApp (per 2026-05-05 process standard), `sqlite3` on `$PATH`. Validates: (a) freshly-rebuilt bundle launches without crash, (b) post-pane-launch `lsof` count `< 1000` (in-process cap is 10240; the 256 launchd-inherited cap was the prior failure mode and is now raised inside the app process via `raiseFileDescriptorLimit()`), (c) zero new `SenkaniApp-*.ips` crash reports, (d) parent-gate Step 5 row-count exact `2000` (Bach's red flag — silent token-event loss fails strict), (e) parent-gate Step 7 ≥ 199 `claude_session_watcher.(attached|rotated)` lines in the unified log. **Out of scope: parent gate's Step 8 (2-hr soak) and Step 9 (post-soak NULL-session_id query)** — those exercise across the full parent gate walk, this validation narrowly covers Steps 1-7 (the sub-sequence the EMFILE crash interrupted). Audit-accepted risks (Torvalds/Evans/Kleppmann groom round): leftover probe files from prior runs change MCPSession startup behavior → Setup cleans `$PROJDIR` of stale `probe-*.jsonl`; `lsof` baseline is informational (Step 4), the pass gate is the post-pane count (Step 9); parent gate's 2-hr soak deferred. Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings (lsof ≥ 1000 → "fix incomplete" follow-up; new `.ips` → "second crash mode" follow-up; row-count mismatch → parent-gate regression filing) to named follow-ups before retry. Groomed 2026-05-15 by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **project-and-workstream-remove-ui-validation-walk-2026-05-14 — Cowork-runnable real-machine validation walk of the new sidebar destructive-action contract (hover X, tiered-checkbox dialogs, create-time disclosure)** ([groomed plan 2026-05-14, re-groomed 2026-06-09](../../spec/autonomous/backlog/project-and-workstream-remove-ui-validation-walk-2026-05-14.md), [parent build round](../../spec/autonomous/completed/2026/2026-05-14-project-and-workstream-no-remove-ui-2026-05-14.md)). Exec mode: **cowork end-to-end** with one operator-only hover sanity-check at step 28 (the one area where Cowork-driven synthetic mouse motion may diverge from real-operator-mouse hover delivery). Time estimate: **~37-47 min operator-supervised** (9 min shell + 27-37 min GUI + 1 min hover sanity). 28-step plan (+ steps 14b/14c branch-state verdict swap, 18b safety cleanup) covers all 14 acceptance bullets: hover→X→sheet on project + workstream rows; dialog layout (disabled-checked Sidebar entry, default-checked app-support row with resolved path, per-child-workstream toggle pairs); yellow ⚠ on BOTH branch-state verdicts (`.noUpstream` never-pushed at step 14 + `.unpushed(count:)` ahead-of-upstream at step 14c — the `.noUpstream` render shipped in `24dcef2`); greyed-out missing worktree toggle; red Confirm button; Esc dismiss-no-side-effects; SHIPPED removal order (worktrees → branches → app-support → sidebar — worktree-first per `remove-step-ordering-worktree-before-branch-2026-05-21`/`6025e7e`) verified by filesystem inspection; dual-toggle failure surfacing (TWO `RemovalFailure` rows: dirty worktree + checked-out branch) + force opt-in checkbox + ONE-click force-retry heal; workstream X suppression on default + lone; NewWorkstreamSheet disclosure block + branch override + non-git degraded note. Pre-condition: working tree on `main`, no running SenkaniApp (`pgrep -fl SenkaniApp` empty per 2026-05-05 process standard), bundle fresh via `senkani walk rebuild-bundle <bundle>` (or `senkani doctor` check #20 green), `~/.senkani/workspace.json` backed up + cleared (Setup script does this idempotently; Teardown restores). Fixture: throwaway projects under `/tmp/senkani-walk-remove-ui-<RUN_TS>/projects/` — projA (git + remote), projB (git + remote; its beta branch walks `.noUpstream` → push `-u` + 1 ahead commit → `.unpushed(1)`, then gains a dirty worktree), projC (non-git). Audit-accepted risks (Norman/Torvalds/Kleppmann groom): hover-event delivery (covered by operator sanity check step 28); workspace.json hardcoded path no env override (covered by backup/restore); the two branch-state verdicts share the same ⚠ icon and differ only in tooltip — the re-groomed plan distinguishes them by deterministic fixture state per step rather than accepting either. **Fixes shipped (re-groom 2026-06-09 via `project-workstream-remove-walk-regroom-2026-06-09`):** the 2026-05-14 pre-grooming finding `remove-retry-sidebar-mutation-leak-2026-05-14` is FIXED (`de69752`, 2026-05-21 — sidebar drop deferred behind `failures.isEmpty`), removal order is worktree-first (`6025e7e`, 2026-05-21), retries are idempotent against already-cleaned artifacts (`4ce524e`, 2026-05-21), and the `.noUpstream` ⚠ render landed (`24dcef2`, 2026-06-09). Steps 17-18 now validate the headline dual-toggle ONE-click force-retry heal (pinned by Suite 7d `dualToggleForceRetryHealsInOneCall`; 34 swift-testing cases across 7 suites in `ProjectWorkstreamRemoveUITests.swift`); observing the old leak signature (sheet dismisses, worktree still on disk) is a REGRESSION → FAIL + file the named follow-up from the plan's failure-modes table. Groomed 2026-05-14, re-groomed 2026-06-09 against the shipped fixes by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **release-v0-3-0-onboarding-pass-milestones-4-7-walk-2026-05-11 — cross milestones 4–7 + env-var no-op verification on a fresh install** ([groomed plan](../../spec/autonomous/backlog/release-v0-3-0-onboarding-pass-milestones-4-7-walk-2026-05-11.md)). Exec mode: **either, but split** — Steps 1, 5, 7-13 are shell or observe (Cowork-runnable end-to-end); Steps 2-4, 6 are `gui (cowork)` (Cowork drives Welcome → Claude pane / Budgets / Workstreams / Sprint Review via screenshots + clicks); only step 11's `SENKANI_ONBOARDING_MILESTONES=off` relaunch is split — `open _onboarding-pass-SenkaniApp.app` typically Cowork-drivable, but if `open` strips env vars on this macOS version, the fallback `env ... _onboarding-pass-SenkaniApp.app/Contents/MacOS/SenkaniApp &` direct-launch may need operator hands the first time. Time estimate: **~30-45 min operator-supervised** if Sprint Review pane has staged proposals available; **pauses indefinitely at step 5** if not (compound-learning daily sweep hasn't fired or has nothing to stage on a fresh install). Pre-condition: iCloud Drive Desktop & Documents sync DISABLED (see `build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09`), `swift build -c release` green, SenkaniApp bundle present at `_onboarding-pass-SenkaniApp.app` and registered with LaunchServices, a project added in the sidebar, `~/.senkani/onboarding/milestones.json` exists at mode `0600` with at least `{projectSelected, agentLaunched, firstTrackedEvent}` baseline. Validates: 4 milestone enum cases (`firstNonzeroSavings` lowercase z, `firstBudgetSet`, `firstWorkstreamCreated`, `firstStagedProposalReviewed`) land in milestones.json with fresh ISO8601 timestamps on real-workload triggers; Welcome banner suppresses the "Next: <milestone>" nudge after `summary.allComplete` flips true; mode 0600 holds across all writes; `SENKANI_ONBOARDING_MILESTONES=off` no-op verified via byte-identical pre/post file diff (canonical step: `senkani onboarding milestones` — read-only verification subcommand that prints the live gate state, the resolved path, the file's pretty-printed JSON, and a derived `summary.allComplete`; reads bypass the env gate so `=off` still surfaces on-disk truth, making "is the gate active AND did the file actually freeze?" answerable in one invocation; `cat ~/.senkani/onboarding/milestones.json` is the script fallback when the `senkani` binary isn't on PATH) and live `ps -E` confirmation of the env var on the launched process. Audit-accepted risks (Norman + Handley + Sutton groom round): milestone 7 requires Sprint Review to have staged proposals — for deterministic walks the operator (or Cowork) now runs `senkani sprint-review seed-fixture` at step 5 to seed one synthetic staged row (shipped 2026-05-13 via `onboarding-milestone-7-sprint-review-seeder-2026-05-13`); the seeded row is visually unmistakable (id prefix `seed-fixture-`, command name `seed-fixture`) and Accept/Reject fires the milestone through the unchanged `SprintReviewViewModel.accept`/`.reject` dispatch — falls back to waiting on the compound-learning daily sweep only if the seeder refuses (already-completed milestone without `--force`); `open` env-var-propagation behavior is macOS-version-dependent (fallback documented); `firstNonzeroSavings` requires the Filter/Cache layers to produce a non-zero saving on the Claude session — may need retry with a context-heavy prompt or repeated identical reads to force cache hits. Pre-audit corrections applied during groom: Milestone 4 enum case is `firstNonzeroSavings` (lowercase `z`, not capital `Z` as the operator's original draft used); Milestone 7 surface is **SprintReviewPane** (`Sources/Core/SprintReviewViewModel.swift:242,261`), NOT DiffViewerPane as the operator's draft claimed. Groomed 2026-05-11 by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize (which will also flip the parent `release-v0-3-0-onboarding-pass` to `status: done` and unblock `release-v0-3-0-surface-pass` + drop one `blocked_by` from `release-v0-3-0-promote-changelog-heading`). **Status note 2026-05-15: closed across the three-attempt arc (05-11 blocked at M4 savings-zero; 05-13 closed M4/M5/env-var/mode-0600 with M6+M7 filed as `onboarding-milestone-6-workstream-create-discoverability-2026-05-13` + `onboarding-milestone-7-sprint-review-seeder-2026-05-13`; both fixes shipped 05-13/05-14, M6+M7 organically crossed 05-14/05-15, banner-disappears verified 05-15). All 7 acceptance lines PASS. Parent `release-v0-3-0-onboarding-pass` had already closed 2026-05-14 via independent walk evidence; this close removes the descendant gate. Archived at `spec/autonomous/completed/2026/2026-05-15-release-v0-3-0-onboarding-pass-milestones-4-7-walk-2026-05-11.md`.**

- **step9-rewalk-cleanup-migration-validation-2026-05-11 — fresh re-walk of the updated Step 9 plan (Step 6 retargeted at cleanup-migration); confirms parent's PASS** ([wrapper item](../../spec/autonomous/backlog/step9-rewalk-cleanup-migration-validation-2026-05-11.md), [test plan = parent file](../../spec/autonomous/backlog/uninstall-rewalk-step9-apppreferences-2026-05-11.md)). Exec mode: **either, but split** — same as parent (Steps 1-5 + Setup + 6b are shell, Cowork-runnable; Step 6a SenkaniApp relaunch via Xcode Play button is operator-only first-grant on first Gatekeeper prompt). Time estimate: **~4-7 min standalone (Mode A), ~30s incremental folded into next full uninstall walk (Mode B)**. **What changed:** the pre-retarget Step 6 (FCSIT first-use popover hover) was N/A on the 2026-05-11 walk because the popover surface was retired same-day in `fcsit-pane-toggles-ux-redesign`. Step 6 now tests the cleanup-migration contract: post-wipe + SenkaniApp relaunch, `defaults read dev.senkani.app senkani.fcsit.firstUseDisclosureSeen.v1` reports the key as absent (exit=1), AND the full `dev.senkani.app` domain post-launch contains only SwiftUI auto-state (`NSWindow Frame …`, `senkani.selectedThemePath`) — proving `SenkaniGUI.init() → cleanupRetiredFCSITFirstUseKey()` (`SenkaniApp/App/SenkaniApp.swift:34-46`) ran on launch and idempotently removed the retired key. Validates the SAME parent acceptance signals (scanner wipes main + ByHost + cfprefsd cache + BROAD sweep clean) plus the new cleanup-migration assertion. Operator contract on PASS: concurrent close of BOTH this wrapper AND the parent re-walk file (`uninstall-rewalk-step9-apppreferences-2026-05-11`), with the new attempt appended to the parent's `rewalk_attempts` frontmatter list. Audit-accepted risks (re-groom 2026-05-11): Step 6 surface retired same-day — accepted because `Tests/SenkaniTests/OnboardingP2DisclosureTests.swift:80-87,184-186` pin both the retired-key string AND that the App init invokes the cleanup, so future re-introduction would break the test pin. Plan-bug #2 (Setup probe (3) `Senkani install detected` grep vs. current binary `Senkani Uninstall` header) is **deferred to a separate round** per operator sequencing — does not block this re-walk's substantive PASS signal (operator can ignore `install-probe: FAIL` since Step 1 still proves the install was detected). Filed 2026-05-11 by `senkani-autonomous` close of `step9-rewalk-plan-step6-references-retired-popover-2026-05-11`; awaits operator/Cowork execution.

- **claude-session-watcher-cancel-handler-race-fix-2026-05-14 — stress-harness + 2h soak validation gate for the 6-luminary-audited cancel-handler-race fix shipped under the same item** ([groomed plan](../../spec/autonomous/backlog/claude-session-watcher-cancel-handler-race-fix-2026-05-14.md)). Exec mode: **either, but split** — Setup + Steps 1, 3-5, 7, 9 (build, harness, DB-query, log-grep, teardown) are Cowork-runnable shell end-to-end; Step 2 (app-launch confirmation screenshot) and Step 8 (2-hour soak with periodic screencaps) are `gui (cowork)` using `mcp__computer-use__screenshot` — operator hands only required if macOS prompts for Notifications/Accessibility on first launch. Time estimate: **~2h 30min wall-clock, ~20-25 min active operator attention** (10-15 min Setup + harness + DB query + ~5 min hands-on during 2h soak + ~2 min teardown). Pre-condition: HEAD includes the cancel-handler-race fix commit (`SenkaniApp/Services/ClaudeSessionWatcher.swift` serial-queue + capture-fd refactor); no running SenkaniApp (per 2026-05-05 process standard); test project's `~/.claude/projects/-Users-clank-Desktop-projects-senkani/` is empty or moved aside; clean DB baseline recorded. **Bach's red flag is the load-bearing gate (Acceptance row 5):** row count exactly `2000` (= N×M = 200×10) of `token_events` matching `source='claude_session' AND session_id LIKE 'probe-%'` after the harness completes — a row count of 1999 or less is silent token-event loss and fails the acceptance strict, even with no visible crash. Validates: (a) serial-queue funnel closes the `EXC_BREAKPOINT` race on burst rotation, (b) capture-fd-locally pattern prevents the cancel handler from closing the wrong fd, (c) no silent event loss (Bach P0), (d) `claude_session_watcher.rotated` observability lines fire per rotation (Allspaw P2), (e) 2-hour soak with no new `SenkaniApp-*.ips` reports. Audit-accepted risks (6-member roster — Torvalds/Carmack/Allspaw/Bach/Majors/Jobs): `processedFiles` unbounded growth deferred to multi-week-soak concern (Majors F2, not material now); restart re-emit filed separately as [[claude-session-watcher-restart-double-count-2026-05-14]] (Jobs P3); 4 other listener-socket call sites with same race shape filed separately as [[dispatch-source-cancel-handler-self-fd-race-listeners-2026-05-14]] (Torvalds NEXT AUDIT TARGETS). Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings (row-count mismatch, soak-crash recurrence, missing rotation log entries) to named follow-up filings before retry. **Audit-trail note:** the fix was implemented from `/Users/clank/.claude/plans/twinkly-giggling-teacup.md` rather than from a backlog item — this item retroactively brings the cancel-handler-race fix into the autonomous-loop audit trail. Filed as `manual_ready` (not `done`) because the stress-harness correctness assertion was not yet run when the WIP was committed; closing as `done` without that gate would be exactly the silent-loss failure mode Bach's audit warned against. Groomed 2026-05-14 by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09 — Phase C operator gate for the iCloud-Drive Desktop & Documents sync remediation + clean-build verification** ([archived plan](../../spec/autonomous/completed/2026/2026-05-11-build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09.md)). Exec mode: **either, but split** — Step 1 (System Settings → Apple ID → iCloud → Drive → Sync this Mac OFF / Desktop & Documents OFF, choose "Keep a Copy") is operator-only `gui (human)` ~3-5 min; Steps 2-6 (`git status` integrity check, `rm -rf .build`, `swift package resolve && swift build -c release && swift build -c debug` clean-build verification, `senkani doctor` reports green, 24h soak gate) are shell, Cowork-drivable end-to-end ~15-25 min plus a ~30 s next-day re-check. Time estimate: **~20-30 min initial operator-supervised** (Step 1 needs hands; Steps 2-5 paste-mode-runnable from a real terminal — NOT the Bash-tool sandbox, since the sandbox itself doesn't see operator iCloud state) **plus ~30 s 24 h later** for Step 6 soak re-check. Pre-condition: senkani build round shipped Phase A doctor extension + Phase B docs (this round, 2026-05-09); SenkaniApp / senkani CLI not running (per 2026-05-05 process standard) so dataless-flag deletion isn't re-evicted mid-cleanup; operator has space outside iCloud (~5 GB) for the post-disable local copies if any; six other operator projects under `~/Desktop/projects/` (customCMS, nonprofitEventPlanner, remixCMS, senkani, terminalHelper, uiExplorer) are at clean-checkpoint commits before the toggle (the disable affects the whole `~/Desktop/` tree, not just senkani). Validates: working-tree integrity post-disable (`git status` shows the same untracked/modified set as before the toggle; no tracked file content lost), `.build/` recovery (`rm -rf .build` completes WITHOUT "Directory not empty" error in <60 s wall-clock), clean build (`swift package resolve && swift build -c release && swift build -c debug` all complete cleanly; `.build/checkouts/` contains NO `* 2` siblings, NO `dataless`-flagged files via `ls -lO@ .build/checkouts/swift-sdk/` — no `dataless` in the flag column), `senkani doctor` reports green on the post-remediation tree (no FileProvider warnings from check #19 — `Sources/CLI/FileProviderEvictionCheck.swift` shipped this round). 24h soak gate: re-run `swift build` next day to confirm no recurrence of `* 2` siblings or `dataless` flags. **Close gate (after Phase C green):** parent item `release-v0-3-0-test-build-broken-mlx-swift-lm-mlxlmcommon-2026-05-09` unblocks (its `blocked_by` list has this build-env item removed) and proceeds to Phase 1 hypothesis verification on a clean `.build/` — if MLXLMCommon emit failure clears with iCloud out of the picture, parent item closes as "shipped via build-environment fix"; if it persists, parent's upstream-package theory is confirmed and parent proceeds to Phase 1.5 SHA-change branch. Operator contract on close: paste captured evidence (`ls -lO@` output, `swift build` walltime, `senkani doctor` summary, 24h re-check date) into a `## Execution evidence` section in the per-item file, flip frontmatter `status: manual_ready` → `status: done` + `shipped: <today>`, run `/senkani-autonomous` so the next round's close-mode sweep finalizes. Groomed 2026-05-09 by `senkani-autonomous` (scope-groomed 2026-05-09; built Phase A + B 2026-05-09). **Status note 2026-05-11: Cowork executed the test plan alongside the parent close in the same session — Phase 1 (operator disabled iCloud Desktop & Documents sync, "Keep a Copy" path after one false-start), Phase 2-5 green on discriminator pair (`swift build -c debug` 141.42 s, `swift test` 228 s with 2559 passes, no `* 2` or `dataless` symptoms in `.build/checkouts/`). 24h soak bullet converted to a passive watch: the shipped FileProvider eviction scanner (check #19) catches recurrence at run-time. Item finalized via `/senkani-autonomous` close-mode sweep and archived to `completed/2026/2026-05-11-build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09.md`.**

- **test-suite-flake-reverification-2026-05-07 — re-verify URLProtocol + FSEvents flakes on real-machine session, three-pass `swift test` + tally summary** ([groomed plan](../../spec/autonomous/backlog/test-suite-flake-reverification-2026-05-07.md)). Exec mode: **either** (shell-only; Cowork paste-mode-runnable from a real terminal — NOT the Bash-tool sandbox, which itself contaminates the FSEvents subscription path and is the suspected source of the original 7 issues from the 2026-05-07 build-broken closing run). Time estimate: **~30-50 min operator-supervised**, ~5 min active attention (3 × `swift test` runs of ~10-15 min wall each, plus tallies + diagnosis). Pre-condition: gate-trait files present on the verification branch (`Tests/SenkaniTests/MockURLProtocolGate.swift`, `Tests/SenkaniTests/FSEventsGate.swift`) AND `.urlProtocolGate` / `.fsEventsGate` trait references applied (2/2 + 5/5). **Pre-audit finding (2026-05-07):** those gate files do not exist on `main` HEAD — they live only on `fix/pane-refresh-worker-pool-test-flake` and were never merged (PR #16 only carried `e9441c3`, the saturatedPoolQueuesWaiters de-flake). The plan's pre-condition step hard-fails closed on main today and short-circuits to the `unmerged-fix` close path. To run the plan productively, first land `integrity-completed-items-vs-fix-branch-divergence-2026-05-07`'s chosen resolution path. Groomed 2026-05-07 by `senkani-autonomous`.

- **phase-t4c-credential-vault-real-keychain — real macOS Keychain backend + `senkani vault` CLI + adversarial-corpus zero-leak validation** ([groomed plan](../../spec/autonomous/backlog/phase-t4c-credential-vault-real-keychain.md)). Exec mode: **either, but split** — Step 1 (`senkani vault add` with getpass + first-run TCC/keychain GUI prompt) is operator-only `gui (human)` ~1 min; Steps 2-9 + teardown are Cowork-runnable shell end-to-end ~12-17 min. Time estimate: **~15-25 min total operator-supervised** (~5 min hands-on attention for the prompt + final visual confirm; the rest Cowork-drivable unattended). Pre-condition: T.4c implementation Phase A committed (`MacOSKeychainStore`, `Vault` ParsableCommand, `Doctor.--vault-status` flag, `HookRouter.credentialVaultLookup` actor bridge, `tools/soak/t4c-corpus-runner.sh`); `swift build -c release` clean; `./tools/test-safe.sh` green; macOS login keychain unlocked; no running senkani process (per 2026-05-05 process standard). Validates: `MacOSKeychainStore` round-trips Data via `SecItemAdd/CopyMatching/Delete` against the operator's login keychain, `vault list` shows `(scope, key, byte_length)` with **zero** value bytes, `doctor --vault-status` reports `vault round-trip OK / N ms` + per-scope counts, `MacOSKeychainStore.read` p95 < 5 ms over 100 reads (with portable `python3 -c 'import time;print(time.time_ns())'` fallback since macOS lacks `gdate`), 20-call `senkani-mcp` adversarial corpus carries gateway injection on tool env without leaking the seeded `SENKANI_SENTINEL_<RUN_TS>` value into ANY of the four chained tables (`token_events`, `confirmations`, `validation_results`, `sandboxed_results`) OR the raw bytes of `~/.senkani/senkani.db` OR any captured plain-text artifact under `${EVIDENCE_DIR}/`, `senkani doctor --verify-chain` (T.5) passes after the corpus, teardown removes the sentinel via both `vault remove` and raw `security delete-generic-password`. Audit-accepted risks (Schneier + Cavoukian + Torvalds groom round): TCC prompt non-determinism on Step 1 (machines that previously trusted `senkani` won't re-prompt — accepted, hint says "click Always Allow if prompted"), Console.app system-log scan deferred to a future hardening pass (current redaction proof is bounded to deliberately captured artifacts), latency probe has a documented fallback if T.4c ships a different surface than `--latency-runs N --latency-key KEY`. Inherits the `no-running-senkani` pre-condition probe per 2026-05-05 process standard. Failure-mode rows route DEFECT-OUTSIDE-CRITERIA findings to named follow-up backlog items (`phase-t4c-defect-vault-list-leaks-value-<RUN_TS>`, `phase-t4c-defect-keychain-latency-regression-<RUN_TS>`, `phase-t4c-defect-audit-chain-leaks-value-<RUN_TS>`, `phase-t4c-defect-sqlite-blob-leak-<RUN_TS>`, `phase-t4c-defect-chain-verify-fail-<RUN_TS>`) before retry. Teardown is mandatory even on failure (sentinel pollution would corrupt future runs). Groomed 2026-05-06 by `senkani-autonomous`; awaits operator Phase A wiring + Phase B execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **phase-t2-pii-classifier-backend-wiring — PIIClassifier MLX/GGUF backend wiring + real-machine perf validation** ([groomed plan](../../spec/autonomous/backlog/phase-t2-pii-classifier-backend-wiring.md)). Exec mode: **either, but split** — Phase A (Xcode wiring of `PIIClassifierAdapter.{ensureModel,forward,runVerificationFixture}`) is operator-only, ~2-6 hours; Phase B (validation: pull → verify → cold-start + warm-p95 timing → BIOES-decoder real-spans assertion → full suite) is Cowork-runnable shell end-to-end, ~30-60 min. Time estimate: **~3-7 hours total operator-supervised** with the validation tail Cowork-drivable unattended. Pre-condition: Apple Silicon (M1+), ≥16 GB RAM, ≥3 GB free on `~/Documents`, HF `openai/privacy-filter` reachable without auth, `~/Documents/huggingface/models/openai/privacy-filter/` not yet present (so the pull truly downloads), Phase A wiring committed locally. Validates: the model-card example string round-trips two PII spans (`private_person` "Harry Potter", `private_email` "harry.potter@hogwarts.edu") with score>0.95, cold-start <2s, warm-p95 <50ms, logits shape `[T, 33]` (NOT `[1, T, 33]`), backend choice (MLX-Swift Apex/MoE vs GGUF/llama.cpp) recorded, weight SHA256 + HF revision SHA captured for tamper-evidence. Audit-accepted risks (Karpathy + Schneier groom round): MLX precision drift may push scores into 0.85-0.95 band on INT8 sparse-MoE — record raw scores, not pass/fail; cold-start <3s acceptable on slower SSDs; HF revision is recorded post-pull rather than pinned (future hardening). Groomed 2026-05-06 by `senkani-autonomous`; awaits operator Phase A wiring + Phase B execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **release-v0-4-0-mlx-pin-bump-pass — RELEASE-CUT GATE for `mlx-swift-lm` pin bump before v0.4.0 cut** ([groomed plan](../../spec/autonomous/backlog/release-v0-4-0-mlx-pin-bump-pass.md)). Exec mode: **either** (purely shell-driven; Cowork-runnable end-to-end via Bash, no GUI hands needed). Time estimate: **~45-90 min wall-clock** (`./tools/test-safe.sh` × 2 + `senkani ml-eval` × 2 dominate); **~10-15 min operator-supervised** attention at decision points. Pre-condition: clean working tree, Apple Silicon, ≥ 8 GB free RAM, `senkani` + `senkani-mcp` built (release), at least one Gemma 4 tier installed locally, network reachable to github.com + huggingface.co. Two paths: **(a)** apply the bump if upstream advanced and post-bump build/test/inference smoke is green — refresh `Package.swift:23-60` rationale + CHANGELOG; **(b)** reject the bump with a documented regression — revert Package edits, refresh rationale only, CHANGELOG records the held-pin decision and rejected upstream state. Embed smoke uses an in-band `python3 - <<PY` heredoc that drives the MCP `embed` tool over stdio (raw wire name, not the `senkani_embed` display alias). Evidence captured under `tools/soak/evidence/v0-4-0-mlx-pin-bump/baseline-<TS>/`. Groomed 2026-05-05 by `senkani-autonomous`; awaits operator/Cowork execution at v0.4.0 release-cut time.

- **uninstall-rewalk-step8-modelmetadatacache — confirm `~/Library/Caches/dev.senkani/` no longer survives `senkani uninstall --yes` after the 9th-category ship** ([groomed plan](../../spec/autonomous/backlog/uninstall-rewalk-step8-modelmetadatacache.md)). Exec mode: **either** (purely shell; Cowork-runnable end-to-end via Bash, no GUI hands needed). Time estimate: **~3-5 min standalone (Mode A), ~0 incremental folded into next full uninstall walk (Mode B)**. Pre-condition: `~/Library/Caches/dev.senkani/` directory exists pre-uninstall (organic if any senkani CLI/MCP/SenkaniApp invocation has touched ModelManager); Setup auto-seeds a minimal `models.json` fixture if not — both paths prove the same scanner-removal behavior since the 9th category strips the whole subtree (`Sources/CLI/UninstallArtifactScanner.swift:285`). Inherits the `no-running-senkani` pre-condition probe (per 2026-05-05 process standard above) so transient `~/.senkani/workspace.json` re-seeding can't contaminate evidence. Operator contract documents the defect-outside-criteria filing if `dev.senkani/` survives the wipe (per parent acceptance bullet #3). Recommended: bundle into the next overall uninstall walk (likely `release-v0-3-0-uninstall-pass` v3 or v0.4.0's release pass) rather than a dedicated re-run. Groomed 2026-05-05 by `senkani-autonomous`; awaits operator/Cowork execution → status: done → next `/senkani-autonomous` close-mode finalize.

- **release-v0-3-0-uninstall-pass-v2-plan-amendments — `senkani uninstall` real-install validation, v2 (8 steps incl. split 3a/3b, 6 acceptance bullets)** ([archived plan](../../spec/autonomous/completed/2026/2026-05-03-release-v0-3-0-uninstall-pass-v2-plan-amendments-fix-three-defects-from-2026-05-02-walk.md)). Exec mode: **either** (Cowork-runnable for Steps 1, 2, 3b, 4, 5, 7, 8; Steps 3a + 6 SenkaniApp launch need operator hands on first Gatekeeper prompt — bundle is ad-hoc signed). Time: **~12-18 min operator-supervised** (down from 65 min on v1's walk; v2 removes the runner defects that caused retries). Pre-condition: PR #14 landed, a registered SenkaniApp install, AND `tools/soak/runner/SenkaniApp.app` bundle present + fresh (mtime ≥ newest `SenkaniApp/*.swift`). Three v1 defects fixed: A1 sweep race (split into `sweep_targets`/`sweep_broad`), A3 Step-3 pre-seed (foreground `open -a` of bundled `.app`), A5 Step-7 hardcoded target (now ANY workspace project + mtime ≥ TEST_START_EPOCH). Operator decides whether to re-walk on v0.3.0 or hold for v0.4.0 (recommended) BEFORE running. Groomed 2026-05-02 by `senkani-autonomous`. **Status note 2026-05-03: walked + closed strict-literal green on all six A-bullets; per-item file archived to `completed/2026/`. Three optional follow-up findings (runner-bundle launch defect, 4 BROAD scanner-extension candidates, `! pgrep SenkaniApp` pre-condition) are pending operator decision on whether to file as new backlog items. See CHANGELOG `## v0.3.0 — unreleased` → `### May 3` for the full closure record.**

- **release-v0-3-0-uninstall-pass — `senkani uninstall` real-install validation (v1, 8 steps, 6 acceptance bullets)** ([archived plan](../../spec/autonomous/completed/2026/2026-05-02-release-v0-3-0-uninstall-pass-real-install-validation-6-checks-on-live-macos-session.md)). Exec mode: **either** (Cowork-runnable for Steps 1–5, 7, 8; Step 6 SenkaniApp re-launch needs operator hands on first Gatekeeper prompt). Time: ~15 min operator-supervised plan estimate (actual v1 walk: ~65 min — see v2 plan above for fixes). Pre-condition: PR #14 (`ship/v0.3.0-batch-2026-05-01`) landed and a registered SenkaniApp install. Highest-value step is Step 8 orphan sweep — finds new artifact paths the eight-category scanner missed (the `webContentRuleLists` 8th category came from this exact sweep on the 2026-05-02 walk). Groomed 2026-05-02 by `senkani-autonomous`. **Status note 2026-05-03: walked Cowork-driven 2026-05-02, closed on spirit-pass (A6 strict-clean; A1/A3/A5 fail-strict / pass-spirit); finalized 2026-05-03 (A1–A6 boxes flipped per operator-directed Option A) and archived to `completed/2026/`. Strict-fail follow-ups all tracked separately: v2-amendments CLOSED; runner-bundle-smoke CLOSED; uninstall-scanner-audit OPEN; uninstall-test-plan-prerunning-process OPEN. The v2 plan above amends the runner defects surfaced by this walk.**

---

## Wave-by-wave (most recent first)

### release-v0-3-0-onboarding-pass — Luminary P0/P1/P2 chain validation on clean install closes pass-with-amendment 2026-05-14

The v0.3.0 release-gating onboarding-pass walk closed today after a
3-day Cowork-driven validation arc (2026-05-11 partial-pass → 2026-05-13
re-walk setup → 2026-05-14 milestones 4-7 + `summary.allComplete`
witnessed → closure).

AC outcomes (final, four-of-four boxes ticked):

- **AC #1 Welcome + FCSIT** — pass-with-amendment. Welcome view (閃蟹 logo
  + project chooser + 4 task starters + milestone hint + "Show all
  panes" escape) renders on every clean-install relaunch. FCSIT
  first-use disclosure popover was retired by commit `b56e221`
  (`fcsit-pane-toggles-ux-redesign`, 2026-05-11) — the replacement
  "click any FCSIT letter → settings panel" surface is the one that
  ships. Filed as Finding #A so the next onboarding-pass walk
  template tests the right surface.
- **AC #2 First task starter + first-value layout** — pass (re-
  verified). "Open a tracked shell in senkani" provisions Terminal
  (primary, active) + Agent Timeline (secondary, insight) panes.
  Sidebar updates to "1 running". Palette-gallery parity holds; no
  inert actions on starter cards.
- **AC #3 Senkani Active proof strip** — pass (re-verified).
  `ActivationProofStrip` renders above the terminal body on the
  active Terminal pane with PROJECT / MCP / HOOKS / TRACK / EVENTS
  chips; absent on non-terminal panes (Agent Timeline) and absent on
  inactive panes. Source-confirmed terminal-only + active-only
  guard.
- **AC #4 Milestones + file mode + env-var** — pass-with-amendment.
  All 7 milestones crossed on one install — `milestones.json` final
  state captured at 374 bytes, mode `0600`, all 7 keys present
  (`projectSelected: 2026-05-14T12:42:47.435Z` … `firstWorkstreamCreated:
  2026-05-14T13:26:41.825Z`). `summary.allComplete` banner-
  disappears witnessed via a freshly-added throwaway project's
  Welcome view rendering with NO bottom milestone banner. The
  `SENKANI_ONBOARDING_MILESTONES=off` env-var no-op verification
  sub-clause stays deferred to Finding #C — no `onboarding` CLI
  subcommand or in-app verification surface ships today, so the env-
  var contract cannot be operator-verified within a walk session
  without a design decision on the inspection path.

Six findings filed today (2026-05-14) + three back-filed from the
2026-05-11 walk:

- `release-v0-3-0-onboarding-pass-AC1-fcsit-popover-acceptance-stale-2026-05-11` — text amendment for future walk templates.
- `uninstall-scanner-extension-candidate-saved-application-state-2026-05-11` — add `~/Library/Saved Application State/dev.senkani.app.savedState/` as a new uninstall scanner category.
- `onboarding-milestones-cli-surface-or-env-var-verification-path-2026-05-11` — scope-groomable; pick CLI subcommand vs in-app surface vs accept `cat`-and-diff.
- `onboarding-milestones-key-casing-mismatch-2026-05-14` — `firstNonzeroSavings` lowercase `z` on disk vs spec text's capital `Z`.
- `workstream-creates-git-worktree-side-effect-2026-05-14` — scope-groomable; intentional design or accidental coupling?
- `pane-close-x-button-drag-handle-collision-2026-05-14` — close X button overlaps right-edge drag handle, reliable close requires finangling.
- `project-and-workstream-no-remove-ui-2026-05-14` — scope-groomable; no UI surface to remove a project or workstream once added.
- `onboarding-pass-stale-bundle-hazard-2026-05-14` — scope-groomable; wrapped `_onboarding-pass-SenkaniApp.app` silently goes stale when new commits land on `main`.
- `onboarding-milestone-recorder-gap-projectSelected-agentLaunched-2026-05-14` — once-only milestones recorded 2026-05-11 were missing from `milestones.json` on the 2026-05-14 walk-resume despite no operator-visible uninstall.

Unblocks `release-v0-3-0-surface-pass` and drops one `blocked_by` from
`release-v0-3-0-promote-changelog-heading`. Per-item file archived to
`spec/autonomous/completed/2026/2026-05-14-release-v0-3-0-onboarding-pass-luminary-p0-p1-p2-chain-validation-on-clean-install.md`.

### onboarding-p2-milestone-callsites — Welcome banner advances on real-machine first run 2026-05-01

Round wired `OnboardingMilestoneStore.record(.X)` into the seven
production callsites so the Welcome banner advances as users use
Senkani. Behavioural tests cover the four Core-side callsites
(`SessionDatabase.recordTokenEvent`, `BudgetConfig.loadFromDisk`,
`SprintReviewViewModel.accept`/`.reject`); the three SwiftUI-side
callsites (`WorkspaceModel.addProject`, `LaunchCoordinator.launchPane`,
`WorkspaceModel.addWorkstream`) are guarded source-level only, since
`SenkaniTests` cannot link `SenkaniApp`. Acceptance criterion was an
explicit real-machine check that the banner advances on at least
three of the seven milestones — that check belongs here.

Walk-through (one user, one fresh launch, ~10 minutes):

- [ ] **Reset state.** `rm -f ~/.senkani/onboarding/milestones.json`
  then launch SenkaniApp. The Welcome banner should read **Next: Pick
  a project** with progress label `0 of 7`.
- [ ] **Pick a project** via the project chooser. The banner should
  flip to **Next: Launch your first agent** (`1 of 7`). Verifies
  `WorkspaceModel.addProject` records `.projectSelected`.
- [ ] **Start Claude in `<project>`** (or any task starter). After the
  pane opens, the banner should advance to **Next: Watch a tool call
  get tracked** (`2 of 7`). Verifies `LaunchCoordinator.launchPane`
  records `.agentLaunched`.
- [ ] **Run any Claude command** (e.g. ask Claude to read a file). The
  Agent Timeline pane should show the event within ~1 s, and the
  banner should advance to **Next: Save your first tokens** (`3 of 7`).
  Verifies `SessionDatabase.recordTokenEvent` records
  `.firstTrackedEvent`. The fourth milestone (`.firstNonzeroSavings`)
  fires the moment the Filter / Cache layer reports a non-zero saving;
  on Claude Code via senkani_read this typically lands inside the
  same first session.
- [ ] **Set a daily budget.** Edit `~/.senkani/budget.json` to add a
  non-default limit, e.g. `{"dailyLimitCents":1000,"softLimitPercent":0.8}`.
  Trigger a tool call so `BudgetConfig.load()` re-reads from disk
  (the cache TTL is 30s; a fresh launch also works). The banner
  should advance to **Next: Create a workstream** (`5 of 7`).
  Verifies `BudgetConfig.loadFromDisk` records `.firstBudgetSet`.
- [ ] **Create a non-default workstream** in the project sidebar.
  After the worktree creation succeeds the banner should advance to
  **Next: Review a staged proposal** (`6 of 7`). Verifies
  `WorkspaceModel.addWorkstream` records `.firstWorkstreamCreated`.
- [ ] **Open Sprint Review** and approve or reject a staged
  proposal (any kind). The banner should disappear (`7 of 7`,
  `summary.allComplete == true`). Verifies
  `SprintReviewViewModel.accept`/`.reject` record
  `.firstStagedProposalReviewed`.
- [ ] **Verify the privacy posture.** `cat ~/.senkani/onboarding/milestones.json`
  — every entry should be `{milestone-key: ISO8601-timestamp}` only,
  no project paths, no session IDs. Then re-run with
  `SENKANI_ONBOARDING_MILESTONES=off senkani` (or the same env on
  the SenkaniApp launch) and confirm the file is not re-written.
- [ ] **Optional regression check.** Re-trigger any milestone (e.g.
  add a second project). The on-disk timestamp for `.projectSelected`
  must remain unchanged — the store guarantees first-observation wins
  and callsites must not double-write.

Tick the date line below when this walkthrough has been done on a
real machine.

- [ ] Walkthrough completed: `_____` (date / initials)

### sessiondb-deinit-regression-guard — Periodic revert-and-verify the guard 2026-05-01

Round shipped `Tests/SenkaniTests/SessionDatabaseDeinitTests.swift`, a
30-iteration parallel test that exercises the deinit-on-queue race
fixed in `bisect-sigtrap-source`. The repro is racy by construction —
unit tests can't deterministically time the strong-drop to land on the
queue thread mid-burst — so the periodic check that the test still
*catches* the regression class needs a manual revert-and-verify cycle.
Run this at least once per release candidate, and after any
`SessionDatabase` deinit-path edit:

- [ ] **Revert the reentrancy guard.** In a scratch branch, undo the
  `DispatchSpecific` marker logic in `SessionDatabase.deinit` so it
  becomes the historic `deinit { queue.sync { sqlite3_close(db) } }`
  again. Build is expected to compile; the regression is at runtime,
  not at the type level.
- [ ] **Run the deinit test ≥10 times in a row.**

      for i in $(seq 1 10); do \
        swift test --filter SessionDatabaseDeinitTests || break; \
      done

  Expected: at least one of the ten runs trips
  `swiftpm-testing-helper signal code 5` (SIGTRAP) — the test correctly
  surfaces the regression. If all ten runs pass with the guard
  reverted, the test is no longer effective and needs a wider race
  window (more iterations or a tighter drain) before the next release.
- [ ] **Restore the guard + reconfirm green.** `git checkout` the
  reentrancy guard back, run `tools/test-safe.sh --chunk session` once,
  expect green on first attempt.

Why manual: the test depends on macOS dispatch's preconditioning
behavior, which is OS-version-sensitive. Running on the operator's
real machine — and on whatever macOS the release target is supposed to
ship against — is the only way to know the test is still load-bearing.

### onboarding-p2-early-use-milestones — Local-only early-use milestones 2026-05-01

Round 9 of the Luminary onboarding chain. Pure-Foundation model + store +
progression ship in `Sources/Core/OnboardingMilestone.swift`,
`Sources/Core/OnboardingMilestoneStore.swift`, and
`Sources/Core/OnboardingMilestoneProgression.swift`; the SwiftUI surface is
the new `OnboardingNextStepBanner` rendered inside `WelcomeView`. 15 new
tests pin every leg (enum order, copy completeness, store round-trip +
idempotency + reset + 0600 file mode + env gate + path layout, progression
`next` / `summary` / `elapsed`, source-level Welcome wiring). The pieces
that need a real-machine pass:

- [ ] **Banner appears empty-state on first launch.** With
  `~/.senkani/onboarding/milestones.json` deleted (`rm -f ~/.senkani/onboarding/milestones.json`),
  launch SenkaniApp on an empty workspace. The banner below the task
  starters should read "Next: Pick a project" with a "0 of 7" progress
  label. The banner must not block the project chooser or any task
  starter — they must remain clickable.
- [ ] **Banner refreshes when a milestone is recorded.** Run a quick
  manual record from a debug REPL or a tracked-shell pane:

      swift -e 'import Core; OnboardingMilestoneStore.record(.projectSelected)'

  (or use the operator's preferred manual-record path once the
  `onboarding-p2-milestone-callsites` round lands the real triggers.)
  Re-render the Welcome screen by closing and reopening any pane that
  triggers a workspace update. The banner should flip to "Next: Launch
  your first agent — 1 of 7".
- [ ] **Banner hides when all seven milestones fire.** Manually
  populate every milestone (each `record(.X)` call) and confirm the
  banner disappears entirely from the Welcome surface. The banner
  must not collapse to "7 of 7 done" or any congratulatory state —
  it should be gone.
- [ ] **Privacy gate disables every read and write.** Set
  `SENKANI_ONBOARDING_MILESTONES=off` in the launch environment
  (e.g., `launchctl setenv SENKANI_ONBOARDING_MILESTONES off` then
  re-launch SenkaniApp). The Welcome banner must read the empty-set
  state regardless of what's on disk. Records made while the gate is
  off must not create the file at all (`ls
  ~/.senkani/onboarding/` should not show a `milestones.json` if
  there wasn't one already).
- [ ] **File mode is 0600 on real disk.** After a real-machine
  launch where at least one milestone has been recorded, run
  `ls -l ~/.senkani/onboarding/milestones.json`. Permissions must
  read `-rw-------`.
- [ ] **5-user first-10-minutes research script** (Torres synthesis):
  recruit five new users (no prior Senkani exposure) and observe each
  for the first 10 minutes after `SenkaniApp` launch. Don't intervene;
  let them self-direct. After each session, capture the contents of
  `~/.senkani/onboarding/milestones.json` plus the user's verbal
  notes. The dataset to extract:
    1. Which milestones fired in the 10-minute window?
    2. Time from launch (file mtime of the first recorded milestone)
       to each subsequent milestone — this is the time-to-first-win
       data the `OnboardingMilestoneProgression.elapsed(...)` helper
       reads.
    3. Where did each user stall? Note in their words.
    4. Did the Welcome banner's "Next:" copy match the user's
       perceived next step? Where did it diverge?
  The dataset stays local — these milestone logs do not leave the
  user's machine. Aggregate findings live in
  `spec/inspirations/early-use-research-2026-05-XX.md` (created by
  the operator after the sessions); the per-user JSON files do not.

### onboarding-p2-copy-fcsit-empty-states — FCSIT first-use disclosure + actionable empty states 2026-05-01

Round 8 of the Luminary onboarding chain. Pure-Foundation deciders
ship in `Sources/Core/FCSITDisclosure.swift` and
`Sources/Core/EmptyStateGuidance.swift`; SwiftUI consumers
(`PaneContainerView.featureButton`, the new `FCSITFirstUsePopover`,
`AnalyticsView.chartPlaceholder`, `KnowledgeBaseView.emptyListState`,
`ModelManagerView.emptyStateView`, `SprintReviewPane.emptyState`)
are thin shells over them. 6 new tests pin the deciders + the
SwiftUI wiring source-side. The behavioral / accessibility pieces
need a real-machine pass:

- [ ] **First-launch FCSIT popover fires once.** With the
  `senkani.fcsit.firstUseDisclosureSeen.v1` defaults key cleared
  (`defaults delete <bundle> senkani.fcsit.firstUseDisclosureSeen.v1`
  or via a fresh `~/Library/Preferences/<bundle>.plist`), launch the
  app, open any pane, and hover the FCSIT row in the header. The
  320 pt popover should appear with the title "Five per-pane
  optimizers" and one body line per letter (Filter / Cache / Secrets
  / Indexer / Terse) plus a "Got it" button. The popover should NOT
  appear before any hover or tap. Dismissing via the "Got it" button
  (or `Return` / `Enter` since it carries `.defaultAction`) should
  clear it; re-hovering must NOT re-show it.
- [ ] **Tap-only path works (popover triggers on first tap too).**
  In the same fresh-defaults state, do not hover — tap any FCSIT
  letter directly. The toggle should flip AND the popover should
  appear on the same tap so a touch-only user (Vision Pro) is not
  stranded.
- [ ] **Persistence across launches.** With the seen flag set,
  quit and relaunch the app. The popover must NOT show on first
  hover or tap of any FCSIT letter in any pane.
- [ ] **VoiceOver names every FCSIT toggle.** With VoiceOver on,
  navigate to the FCSIT row in a pane header. Each letter must
  announce as "Filter, on / off" / "Cache, on / off" / "Secrets, on
  / off" / "Indexer, on / off" / "Terse, on / off" plus the effect
  string as the accessibility hint. Verify state-toggle round-trip:
  flip Filter off, VoiceOver should read "Filter, off"; flip back,
  "Filter, on".
- [ ] **Keyboard focus reaches every FCSIT toggle.** Enable
  Full-Keyboard-Access and tab through the pane header. Each FCSIT
  letter should receive focus in order F → C → S → I → T with a
  visible focus ring. `Space` or `Return` on a focused letter should
  toggle it.
- [ ] **Analytics empty state surfaces a concrete next action.**
  Open Analytics on a fresh project with no events. The empty state
  should end with "Launch a tracked session from the Welcome screen
  — savings appear within seconds." (not just "Data will appear as
  commands are intercepted"). Launching a tracked session and
  running one tool call should populate the chart.
- [ ] **Knowledge Base empty state surfaces a concrete next
  action.** Open the Knowledge Base pane on a fresh project. The
  empty state should end with "Run a tracked Claude session and ask
  about the codebase — the first entities land here within one
  session." (not just "Entities appear after Claude mentions
  project components across sessions").
- [ ] **Model Manager empty state surfaces a concrete next
  action.** Open the Model Manager with no models installed. The
  empty state should end with "Install Ollama, then run
  `ollama pull qwen3:1.7b` — the model registers here
  automatically."
- [ ] **Sprint Review empty state surfaces a concrete next
  action.** Open the Sprint Review pane on a project with no staged
  proposals. The empty state should end with "Use Senkani for a few
  sessions; the first staged proposal usually appears within 24
  hours of the first sweep."

### onboarding-p1-first-value-layout — first-value layout 2026-05-01

The first agent launch now assembles a witnessed layout instead of
dropping the user into a single Terminal pane. Picking
**Ask Claude in <project>** or **Open a tracked shell** opens a
Terminal pane plus an Agent Timeline insight pane next to it, so
optimization events appear as the user works without anyone opening
⌘K. Picking Ollama or Inspect skips the insight pane (their primary
panes already carry their own proof/status surface). Subsequent
clicks of the same starter add only the primary pane — no duplicate
timelines. Decider lives in `Sources/Core/FirstValueLayout.swift`
(unit-tested across all four kinds and idempotency); SwiftUI funnel
is `ContentView.assembleFirstValueLayout(for:command:)`. The
behavioral pieces — actual layout / responsive widths / repeated
clicks — need a real-machine pass:

- [ ] **First-run Ask Claude opens Terminal + Agent Timeline.**
  Empty workspace. Pick a project, click Ask Claude, complete the
  launch sheet. Both panes should appear side by side. The Agent
  Timeline empty state should read "No optimization events yet
  / Use the terminal next to this pane — every Senkani-aware tool
  call appears here with bytes saved."
- [ ] **First-run Open a tracked shell opens Terminal + Agent
  Timeline.** From a fresh empty workspace, click the tracked-shell
  starter. Same layout: Terminal + Agent Timeline. The Terminal
  header should read the project root (or `home folder` if no
  project chosen).
- [ ] **First-run Use Ollama opens ONLY the launcher.** Empty
  workspace, pick a project, click Use Ollama. Only the
  OllamaLauncher pane should appear — no Agent Timeline next to
  it. The OllamaLauncher's own header is the proof/status surface.
- [ ] **First-run Inspect opens ONLY the code editor.** Empty
  workspace, pick a project, click Inspect this project. Only the
  codeEditor pane should appear.
- [ ] **Re-clicking Ask Claude does not stack a second Agent
  Timeline.** From the post-first-run state (Terminal + Agent
  Timeline), open the Welcome again (close all panes or use the
  ⌘K palette to reopen Welcome) and click Ask Claude a second
  time. Only one new Terminal should appear; the Agent Timeline
  count must not increase.
- [ ] **Layout fits a 13" laptop display.** With Terminal + Agent
  Timeline visible, the canvas should scroll horizontally if the
  combined column widths exceed the viewport (existing behaviour).
  Both panes should be readable without manual resize. No truncated
  pane titles, no clipped chips on the proof strip.
- [ ] **Layout uses an external display sensibly.** On a 27"+ external
  monitor, the same Terminal + Agent Timeline layout should still
  show both panes side-by-side without leaving most of the canvas
  empty (the existing per-type `columnWidth` defaults are
  responsible — confirm they don't look stranded).
- [ ] **Layout persists through close/reopen.** With the first-value
  layout open, quit the app and relaunch. The Terminal + Agent
  Timeline pair should restore in their original positions
  (workspace persistence runs via `LaunchCoordinator`'s save call).
- [ ] **Agent Timeline empty-state copy is legible at the smallest
  default width.** The new copy is multi-line and centered with
  `padding(.horizontal, 16)`. On a default-width Agent Timeline
  pane the body text should wrap cleanly — no awkward single-word
  lines, no clipping.

### onboarding-p1-task-presets — task-starter Welcome 2026-04-30

The first-run Welcome screen now renders four outcome-first task
starters (Ask Claude, Use Ollama, Open a tracked shell, Inspect
this project) sourced from `Sources/Core/TaskStarterCatalog.swift`
instead of the old per-agent feature inventory. The 18-pane
gallery is one level deeper behind a "Show all panes" link that
opens the existing AddPaneSheet. Each starter resolves to a
deterministic LaunchCoordinator outcome: Claude opens the launch
sheet, Ollama opens the ollamaLauncher pane, tracked shell opens
a terminal, Inspect this project opens the code editor. The
catalog and project-aware rendering are unit-tested but the
end-to-end Welcome flow needs a 10-minute walkthrough on a real
machine. Tick each step as it's verified:

- [ ] **First-run Welcome shows the project chooser before the
  starters.** Launch Senkani in a fresh workspace (no projects
  selected). The window should show the "Choose project folder"
  affordance above any starter cards, and every starter except
  "Open a tracked shell" should be visibly disabled with a
  "Choose a project folder first" subtitle.
- [ ] **Picking a project enables the project-required starters
  and updates labels.** Click "Choose project folder" and pick a
  repo. The four starter cards should rerender — Ask Claude,
  Use Ollama, and Inspect this project become enabled, and each
  label gains the "in <projectName>" suffix. The tracked-shell
  card swaps "in home folder" for "in <projectName>".
- [ ] **Each starter opens the right pane on the first click.**
  Ask Claude → ClaudeLaunchSheet appears, picking a launcher
  opens a Terminal pane in the project. Use Ollama → an
  ollamaLauncher pane opens. Open a tracked shell → a Terminal
  pane opens. Inspect this project → the codeEditor pane opens
  with the project root showing.
- [ ] **"Show all panes" demotes the gallery to one level
  deeper.** From a fresh Welcome, click the "Show all panes"
  link below the four starters. AddPaneSheet should open with
  all 18 pane types. Closing it returns to the four-starter
  Welcome with no extra panes created.
- [ ] **Claude / Ollama install affordances still work when the
  tool is missing.** On a machine without Claude Code installed,
  the Ask Claude card should show "Install" and link to
  claude.ai/download. Same for Ollama.
- [ ] **Time the full first-run walkthrough end-to-end.** Reset
  workspace state, then time how long it takes a fresh user to
  go from app launch → project selected → Claude session live in
  the project. Target ≤ 10 minutes including any tool installs.
  Record the time so the P2 milestone work has a baseline.

### onboarding-p0-active-proof-strip — Senkani Active proof strip 2026-04-30

The active terminal pane now renders a five-chip "Senkani Active"
proof strip (PROJECT, MCP, HOOKS, TRACK, EVENTS) with literal labels,
state tokens, and a banner-row next action when any chip is missing.
The five derivation states are unit-tested but the chip rendering,
the 1-second `TimelineView` tick cadence, and the runnable
next-action recovery flows need eyes-on at least once on a real
install. Tick each line as it's verified:

- [ ] **Fully-ready state shows five OK chips and the `✓ Senkani
  active` prefix.** With Senkani's MCP registered globally, hooks
  installed in the project (`senkani init` already run), the
  terminal pane's session watcher running, and at least one
  Claude command intercepted, the strip should read
  `✓ Senkani active  OK PROJECT ~/<repo>  OK MCP registered with
  Claude Code  OK HOOKS project hooks active  OK TRACK watching
  Claude session  OK EVENTS last <N>s ago` with a faint green
  background tint. No banner row should appear.
- [ ] **No-events-yet shows the `··` waiting token and an
  actionable hint.** Open a brand-new terminal pane in a project
  where Senkani has never logged a token event yet (e.g. a fresh
  test repo). The EVENTS chip should read `·· EVENTS no events
  yet`, the strip's prefix should drop the green check, and the
  banner row should read `Run a Claude command — events should
  land within a second.` Run a Claude command and confirm the
  chip flips to `OK EVENTS last <N>s ago` within ~1 s of the
  next tick.
- [ ] **Missing project hooks surface the `senkani init`
  recovery.** From a project where the global MCP is registered
  but `.claude/settings.json` does not yet carry a senkani-hook
  entry, the HOOKS chip should read `! HOOKS not installed in
  this project` and the banner row should read `Run \`senkani
  init\` in the project root to install hooks.` Run that command
  in the pane, confirm the chip flips to `OK HOOKS …` within the
  next tick.
- [ ] **Missing MCP suggests a re-register.** Manually delete
  the `mcpServers.senkani` key from `~/.claude/settings.json` and
  confirm the MCP chip reads `! MCP not registered` with a banner
  pointing at `senkani mcp-install --global` or "Restart
  Senkani". Restart the app and confirm the chip recovers to
  `OK MCP registered with Claude Code`.
- [ ] **No project / no watcher cases are also reachable.**
  Open a Plain Shell with no saved workspace (the "Open Plain
  Shell in home folder" path) and confirm the strip reports
  `! PROJECT no project selected` with the Welcome-screen
  next-action; tick this off when the banner copy reads as
  intended on a real run. Separately, force the session watcher
  to be unset (e.g. by hot-reload during dev) and confirm the
  TRACK chip reports `! TRACK session watcher not running` with
  the "Restart the terminal pane" next-action.
- [ ] **Strip respects active-pane-only mounting.** Open two
  terminal panes side-by-side; only the focused pane should
  render the strip. Click between panes and confirm the strip
  follows the focus ring without flicker.

### onboarding-p0-project-first-welcome — Project-first Welcome flow 2026-04-30

The empty-workspace Welcome surface now gates Claude / Ollama launches
behind a chosen project, replaces the marketing-copy subtitles with
verb-first project-aware copy, and stops terminal pane headers from
falling back to `~` for sessions that actually live in a real repo.
A real-machine first-run check needs eyes-on:

- [ ] **First run with no projects shows a 'Choose project folder'
  step before agent cards become actionable.** Launch with no saved
  workspace (`rm -rf ~/Library/Application Support/Senkani` or
  equivalent), open the app, confirm the Welcome surface shows the
  `Choose project folder` button at the top and that the Claude +
  Ollama agent cards read `Choose a project folder first` and look
  disabled. Plain Shell stays clickable but its title reads
  `Open Plain Shell in home folder` (no silent default).
- [ ] **Picking a project unlocks the agent cards with project-aware
  titles.** Click `Choose project folder`, pick a real repo,
  confirm the chooser collapses to a `Project: <name>` row with a
  `Change` link, and the agent cards now read
  `Start Claude in <name>` and `Start Ollama in <name>` with active
  styling (no longer dim).
- [ ] **Terminal pane header shows the actual working directory.**
  Launch a Plain Shell into the chosen project; the pane header
  context label should display the abbreviated repo path
  (e.g. `~/Desktop/projects/senkani`) rather than a bare `~`. Cross-
  check by `cd`-ing inside the shell — the header reflects the
  pane's launch directory, not the live shell `pwd` (this is
  expected; the launch path is the truthful identifier).
- [ ] **'Change' affordance re-opens the picker without losing
  panes.** With a project selected and at least one pane open,
  click `Change`, pick a different folder, confirm the new project
  is appended and active. Original panes still belong to the prior
  project (verifiable via the sidebar).
- [ ] **Plain-shell escape hatch is honoured.** From the no-project
  state, click `Open Plain Shell in home folder`. A terminal pane
  opens at `~`, the implicit `Default` project is created (this is
  the documented escape hatch), and the header context label shows
  `~` correctly.

### Phase U.6c round 1 — Plan-variance histogram in AnalyticsView 2026-04-30

Round 3 of U.6 lands the operator-visible chart + the ≥ 90 % pairing
eval. Unit + corpus tests cover the data flow (paired / unpaired /
rejected / throws, histogram bin classification, median residual).
The chart's visual rendering on a real machine needs eyes-on:

- [ ] **Empty-state copy reads correctly with no combinator data.**
  Open Analytics on a fresh-ish session that has zero combinator
  calls. The "Plan Variance — Actual vs. Planned Cost" card should
  render the empty-state copy (chart icon, "No combinator plans in
  this window — variance appears once split / filter / reduce calls
  land traces."). The header stat row should NOT render when no
  bars are drawn.
- [ ] **Under-N threshold copy reads correctly with 1–2 paired
  plans.** Drive a single `split` call through a debug hook (or via
  a future test seam in `OptimizationPipeline`); confirm the chart
  still shows the empty state with the under-threshold message
  ("Need ≥ 3 paired plans for a stable histogram…"). No bars.
- [ ] **Bars render with three or more paired plans.** Drive ≥ 3
  combinator calls (mix of `split` / `filter` / `reduce`); confirm
  the histogram now draws bars colour-coded under (green) / exact
  (gray) / over (red), with the bin labels visible on the X axis
  and a count annotation on top of each non-empty bar. The Y axis
  ticks should be integer.
- [ ] **Header stats reflect ground truth.** With a known mix of
  paired (some over-budget, some under, some exact) + at least one
  rejected plan, confirm the four header cells show the expected
  N paired, unpaired, signed median Δ (with leading `+` when
  positive), and % paired. The percent should round to a whole
  number and never exceed 100.
- [ ] **24h / 7d picker scopes the window without flicker.** Toggle
  the picker between 24h and 7d; the chart should re-render with
  the wider/narrower window's data without showing the empty state
  in between (data is fetched on the same timer tick as tier
  distribution).
- [ ] **Rejected plans appear in unpaired count, never in bars.**
  Drive one combinator call whose `estimatedCost` exceeds the
  active `BudgetConfig` daily-equivalent ceiling. Confirm the
  unpaired count increments by 1 and the histogram bar counts do
  not — rejection and execution must be pivot-distinct.

### Phase V.12b round 1 — HookRouter denials → DiffViewerPane annotations 2026-04-30

Round 2 of V.12 wires `HookRouter` denials into the V.12a sidebar
via `HookAnnotationFeed.shared`. Unit tests cover the data flow
(emit, rate cap, deny-response invariance, rate-cap log). UI
behavior needs eyes-on:

- [ ] **ConfirmationGate deny renders as a `[must-fix]` row.**
  Open the Diff Viewer with two files (left = original, right =
  modified). Inject a deny resolver into `ConfirmationGate` (e.g.
  via a debug hook or by setting `ConfirmationGate.resolver` from
  a scratch script) so an Edit on `<rightPath>` denies. Trigger
  Edit on the right file from Claude Code; confirm a `[must-fix]`
  badge appears in the sidebar with the deny reason as the body
  and `hookrouter:Edit` as the author handle, pinned to the first
  hunk. Click the badge — the diff scrolls to the first hunk.
- [ ] **Read / Bash / Grep redirects do NOT badge.** Trigger a
  vanilla Read on a file in the active diff; no annotation should
  appear in the sidebar. The senkani_read advisory is a routing
  nudge, not a policy violation.
- [ ] **Rate cap suppresses past 5 must-fix in a minute.** Drive
  six ConfirmationGate denies in under a minute via repeated Edits.
  The first five render in the sidebar; the sixth does not. The
  agent still sees the deny in its tool response on every call.
- [ ] **Rate-cap log row appears after window roll.** After the
  flood above, wait 60 s + trigger one more deny. Confirm a row
  appears in `annotation_rate_cap_log` (`sqlite3` query against
  `~/Library/Application\ Support/Senkani/senkani.db`):
  `SELECT severity, suppressed_count, threshold FROM annotation_rate_cap_log ORDER BY id DESC LIMIT 1;`
  should return `must-fix | 1 | 5` (one suppression carried into
  the log).
- [ ] **Multiple Diff Viewer panes don't double-badge.** Open two
  Diff Viewer panes against the same file pair. A single deny
  should badge in BOTH sidebars — both subscribe to the same
  feed. Acceptable today; future cleanup will centralize.

### Phase V.12a round 1 — Hunk render + severity-tagged annotations sidebar 2026-04-30

Round 1 refactors `SenkaniApp/Views/DiffViewerPane.swift` to show
LCS hunk blocks with an annotations sidebar; the four-tag severity
vocabulary `[must-fix]` / `[suggestion]` / `[question]` / `[nit]`
ships frozen with distinct colors + glyphs + labels. Unit tests
cover the layout helpers; UI behavior needs eyes-on:

- [ ] **Hunk blocks render with stable headers.** Open the Diff
  Viewer pane against two files with three or more separated
  changes. Each hunk should render as a labeled `@@ -orig, +mod`
  block with red removed / green added rows. Confirm hunk count
  matches what `git diff` would show.
- [ ] **Severity chip row in the file bar.** All four severity
  chips render even when there are no annotations (counts show 0).
  Order: must-fix / suggestion / question / nit. Hover tooltip
  shows the severity label.
- [ ] **Annotation sidebar.** With no annotations the sidebar
  shows "No annotations on these hunks." (V.12a ships the surface;
  V.12b wires HookRouter denials in — until then the annotations
  list is intentionally empty.) The sidebar header shows
  `Annotations` + count.
- [ ] **Click-to-jump.** Once V.12b lands or while injecting
  fixture annotations via debugger, click any annotation row in the
  sidebar. The matching hunk should scroll into view at the top
  edge with a brief animation. Clicking the same row twice in a
  row must still re-trigger the scroll (state resets between
  clicks).
- [ ] **Colorblind readability.** Squint or run macOS Color Filters
  → Greyscale. Each severity must remain distinguishable by glyph
  + label even with color removed (must-fix octagon, suggestion
  lightbulb, question questionmark.circle, nit scribble).

### Phase U.1c round 1 — Tier-distribution chart in AnalyticsView 2026-04-30

Round 1 ships `AgentTraceEventStore.tierDistribution` + `tracesForTier`
plus the new "Routing — TaskTier Distribution" card in
`SenkaniApp/Views/AnalyticsView.swift`. Unit tests cover the store
queries (counts, NULL-tier exclusion, `since` cutoff, drill-down DESC
+ limit) but Charts rendering and click-to-drill require eyes on the
real machine.

- [ ] **Stacked vs Grouped layout.** Open Analytics in a workspace
  that has TaskTier-tagged traces. Switch between Stacked (default)
  and Grouped — Grouped should split each tier into Primary /
  Fallback 1 / Fallback 2 bars. Confirm legend colors match the
  intended palette (Primary = green, Fallback 1 = yellow, Fallback 2
  = orange) and that bars annotate with their counts in Grouped mode.
- [ ] **24h vs 7d cutoff.** Change the window picker. Bars should
  redraw within ~2 s; counts should be ≤ when narrowing from 7d → 24h
  (never larger).
- [ ] **Click-to-drill sheet.** Click any bar. The drill-down sheet
  should render with the tier name + window in the title, list rows
  newest-first, and close cleanly via Done / Esc. A control row from
  a different tier must NOT appear.
- [ ] **Empty-state copy.** On a fresh DB or in a 24h window with no
  routing data, the empty-state should read exactly: "No routing
  data yet — TaskTier was introduced in u1a; charts populate as new
  traces land." If the wording drifts (e.g. truncation, missing
  hyphen), file a regression — Podmajersky pinned this string.

### Phase W.4 round 1 — `ContextSaturationGate` + `PreCompactHandoffWriter` 2026-04-29

Round 1 ships the gate, the handoff card, and the loader as Core
helpers. Unit tests pin every branch in-process. Three things only a
real session can confirm:

- [ ] **Live saturation read.** Run a long Claude Code session. Pull
  `agentTraceTokenUsage(pane:)` from a senkani CLI shim or a custom
  pane and confirm the running total tracks roughly with the agent's
  reported context-window usage. If the two diverge sharply (>20 %),
  the active-window slice may be wrong for this model and the
  `Threshold.budgetTokens` default needs revisiting.
- [ ] **End-to-end handoff round-trip.** Force a saturation block
  (`evaluate(currentTokens: 180_000, threshold: .default)` →
  `.block`), call `PreCompactHandoffWriter.compose(...) | write(...)`,
  start a fresh session, and confirm `PreCompactHandoffLoader.load(...)`
  returns the card with `currentIntent` and `lastValidation` intact.
  Eyeball the JSON at `~/.senkani/handoffs/<sessionId>.json` for any
  surprise field truncation.
- [ ] **<1 s SLO under real load.** Tests assert <1 s on a quiet
  machine with a small card. Soak: run `write` against a card that
  embeds a 4 KB advisory string AND a full 10-key trace tail while
  the disk is busy with concurrent test output. The SLO should still
  hold; if it doesn't, file the regression because the gate is now
  too expensive to drop into a hook path.

### Phase W.1 round 1 — `senkani_search_web` MCP tool 2026-04-29

Round 1 ships a fully fixture-tested DuckDuckGo Lite backend (host pin,
SSRF guard, redirect pin, `guard-research` query filter, snippet
redaction). Three things only a real run against `lite.duckduckgo.com`
can validate:

- [ ] **Live shape match.** From a real session: call
  `senkani_search_web` with a public topic ("rust async runtime
  comparison"). Confirm the parser pulls out at least 5 results with
  non-empty title + url + snippet. If the regex misses a row, that's
  a DDG markup drift — capture the served HTML for a fixture update.
- [ ] **CAPTCHA backoff visible.** Hammer the tool ~50× in a minute to
  trigger a soft block; confirm the response is `BackendBlocked`
  (structured error, not silent zero results) and that the next call
  after a few minutes recovers.
- [ ] **`autoresearch` preset round-trip.** Install the `autoresearch`
  scheduled preset (`senkani schedule preset install autoresearch`),
  let one fire run, confirm `~/.senkani/research/<date>.md` lands and
  contains LLM-summarised bullets — no `[REDACTED:…]` accidents in
  the summary.

### Phase U.8 round 1 — NaturalLanguageSchedule foundations 2026-04-29

Round 1 shipped the data-model + protocol + math + minimal pane
affordance behind the autonomous loop. The pieces that need a real
machine to validate land in u8b, but the round-1 surface needs at
least one real-machine smoke-check before u8b builds on it:

- [ ] Create a schedule via `senkani schedule create` with a cron,
  then hand-edit `~/.senkani/schedules/<name>.json` to add a
  `proseCadence` field and re-launch the Schedules pane. Confirm
  the row renders the prose pill (not the cron pill) and the tooltip
  shows the compiled cron from `compiledCadence`. (Validates the
  round-1 round-trip path end to end without needing the New
  Schedule form prose input.)
- [ ] Hand-edit a schedule JSON to set `eventCounterCadence: "every
  5 tool_calls"` (and an empty `cronPattern`). Confirm the row
  renders the orange counter-cadence pill with the correct tooltip
  text.
- [ ] Verify pre-U.8 schedule JSON files on disk (the morning-brief
  / autoresearch / log-rotation defaults) still load + render
  exactly as before (cron-direct path).

If any of these surface a regression, mark the round NEEDS-FIX and
file under u8a-fix in the backlog before u8b queues.

### Full-suite test-bundle SIGTRAP — INVESTIGATE 2026-04-28 (pre-existing, found during V.7)

`swift test` (no `--filter`) crashes the test bundle with `signal code 5`
(SIGTRAP) before reaching the summary line. Confirmed reproducible on
`main` without any V.7 changes — this is **not** a V.7 regression. All
focused suites still pass (V.7 added 12 tests; KnowledgeFileLayer × 12,
KBLayer1Coordinator × 5, KBPaneViewModel × 11, WikiLinkCompletion × 14
all green). The crash likely lives in cross-suite parallel test
interaction, not in any single test (each suite passes independently).

What to verify on your machine when you're back at it:

1. Run `swift test --no-parallel` — does the SIGTRAP go away? If yes,
   the failure is races between parallel test bundles (env mutation,
   file system contention on `/tmp`, or shared mutable state).
2. Run the suite in a worktree (`git worktree add ../senkani-soak main`)
   under `swift test --num-workers 1` and capture which suite was last
   running just before the crash. Add `--xunit-output` for a parsable
   transcript.
3. Bisect parallel-unsafe suites: env-mutating tests in
   `KBVaultV7Tests`, `KBVaultConfigTests`, `WorkstreamTests`,
   `FeatureConfigTests` are the usual suspects.

Once isolated, file a follow-up backlog item to either serialize the
offending suite (`.serialized` trait at `@Suite` level) or move the env
read out of process-level state.

### `senkani doctor --repair-chain` UX validation — RUNNABLE 2026-04-27 (Phase T.5 round 4)

Round 4 of T.5 shipped the repair scaffolding green in CI (1879 tests pass, 9
new round-4 tests including the load-bearing pre-segment-OK / post-segment-OK
test). The scaffolding is correct mechanically; the **double-confirm prompt
copy and the typed-string ergonomics** still need a real-tty walk-through
before this round is considered fully shipped.

What to verify on your machine:

1. **Happy path — interactive.** Pick a workspace DB
   (`~/Library/Application Support/Senkani/senkani.db`), pick a real rowid
   in `token_events` (e.g. `sqlite3 ~/Library/Application\ Support/Senkani/senkani.db
   'SELECT MAX(id) FROM token_events;'`), then run:
   ```
   senkani doctor --repair-chain --table token_events --from-rowid <N>
   ```
   Confirm the prompt explanation reads cleanly. Type `REPAIR` then the
   table name. Verify the outcome message lists table / from-rowid / new
   anchor id / prior tip / rows rebound, and the closing line points at
   `senkani doctor --verify-chain`.

2. **`--force` non-tty path.** `echo | senkani doctor --repair-chain
   --table token_events --from-rowid <N> --force` — should run without
   prompts and print the same outcome.

3. **Refusal — non-tty without `--force`.** `echo | senkani doctor
   --repair-chain --table token_events --from-rowid <N>` — should refuse
   with the "refuses non-tty invocations without --force" message, exit
   non-zero.

4. **Wrong typed string aborts.** Run interactively, type anything other
   than `REPAIR` at the first prompt — should print "Aborted (input was
   not 'REPAIR')." and exit non-zero.

5. **Idempotency guard.** Run the repair twice in a row (without
   `--force` on the second). Second invocation should refuse with
   "a repair anchor already exists for '<table>' (anchor id N).
   Use --force to open a second repair anchor."

6. **Verification after repair.** Run `senkani doctor --verify-chain`
   after a repair. Should show `chain integrity: OK across … / 1 repairs`
   (or however many repairs you ran).

If any prompt copy reads ambiguous, file follow-up backlog items rather
than re-opening this round — the scaffolding is fixed; the copy is text
and ships independently.

### Per-RAM-tier Gemma 4 quality eval — RUNNABLE 2026-04-25

Round `luminary-2026-04-24-4-gemma-tier-quality-eval` (harness 04-24)
+ `gemma4-vision-image-fixtures` (vision PNGs 04-25)
+ `senkani-ml-eval-cli` (CLI + MCP-backed inference adapter 04-25).
The full chain is now wired end-to-end: 20-task harness in
`Sources/Bench/MLTierEvalTasks.swift` (10 rationale + 10 vision) with
`MLTierEvalRunner.evaluate` accepting a caller-provided inference
closure; `MCPServer.MLTierInferenceAdapter` loads each Gemma 4 tier in
turn through `VLMModelFactory.shared.loadContainer` and answers tasks
via `MLXInferenceLock.shared`; `MCPServer.MLTierEvalOrchestrator`
plans evaluate-vs-skip per tier (allowlists `.verified`/`.downloaded`,
records `notEvaluated` with named reason for `insufficient RAM` /
`not installed` / `not in registry`); `senkani ml-eval` CLI shells
out to `senkani-mcp eval` so the everyday `senkani` binary stays
MLX-free; JSON written atomically to `~/.senkani/ml-tier-eval.json`;
`senkani doctor` cache-reader + Models pane quality badge surface
ratings to the user. The harness is **no longer dormant** — every
bullet below is exercisable on a machine with at least one Gemma 4
tier installed.

- **Real measurements on a machine with ≥1 Gemma 4 tier installed.**
  Prereq: at least one Gemma 4 tier (`gemma4-26b-apex` / `gemma4-e4b`
  / `gemma4-e2b`) downloaded + verified via the Models pane. Run
  `senkani ml-eval`. Expect: writes `~/.senkani/ml-tier-eval.json` with
  per-tier `passed`, `total`, `medianLatencyMs`, `totalOutputTokens`,
  `rating`. Re-run `senkani doctor` — the `ml.tier.<id>` line should
  appear with the rating string. If the lowest tier the machine can
  load rates `degraded`, doctor exits non-zero with the upgrade hint.
  Tiers above this machine's RAM should appear as `notEvaluated`
  with reason `insufficient RAM (N GB; tier requires M GB)` rather
  than be silently absent. Sanity check the `outputTokens` figures —
  current implementation counts MLX `Generation.chunk`s as a token
  proxy (doc-commented in `MLTierInferenceAdapter.run`); if MLX gains
  a precise per-chunk token count, swap the source and refresh the
  numbers.

- **8 GB-machine validation: E2B rating is honest.** On a real 8 GB
  Mac, after running the eval, confirm `gemma4-e2b` is the
  recommended tier (Models pane shows "Recommended" badge) AND its
  quality rating is visible inline. If E2B comes back `degraded`,
  the Models pane should still recommend it (it's the only fitting
  tier) but the doctor warning is the user's signal to consider an
  upgrade. Verify the doctor message is non-condescending and
  actionable.

- **16 GB-machine validation: APEX 26B beats E4B by ≥10 pp.**
  On a 16 GB+ Mac with both APEX and E4B downloaded, the eval should
  show APEX 26B at a strictly higher pass rate than E4B (the
  measured-vs-marketing-claim check). If APEX rates ≤ E4B, that's a
  signal the APEX install is broken or the harness is off — file a
  backlog item, don't paper over it.

- **Median latency stays under 1 s for E2B/E4B, under 3 s for APEX.**
  Per-tier latency ceilings sanity-check the Phase G live-session
  multiplier model. Anything slower means the Gemma load path
  regressed and rationale rewriting will materially slow down a
  live session.

### Test harness hang workaround (shipped 2026-04-21)

Round `test-harness-sigtrap-repro`. `.serialized` trait added to three
parallel-hostile suites, `tools/test-safe.sh` added for deterministic
full-suite runs. Targeted regression (32 tests) is green under
parallel `swift test`. What the unit tests cannot cover: a full-suite
run on a real machine, end-to-end. These steps close that loop.

- **`./tools/test-safe.sh` completes end-to-end.** Run from a clean
  worktree on the original hang-reproducing machine. Expect:
  wall-clock 10–30 min (slow but deterministic), exit code 0, no
  SIGINT needed. Confirms the `SWT_NO_PARALLEL=1 --no-parallel`
  incantation resolves the hang on this machine. If it hangs: the
  operator's hang repro is broader than the three suites named in
  `spec/testing.md` "Full-suite hang"; re-capture frames via
  `sample <pid>` and file a new backlog item.

- **`swift test` (default parallel) no longer hangs on the three
  named suites.** Run `swift test --filter "ScheduleWorktreeTests|
  PaneSocketMigrationTests|WatchRingBufferTests"` from the
  hang-reproducing machine. Expect: terminates in <10s with all
  tests green. Confirms the `.serialized` traits converted the
  intra-suite parallelism into sequential access to the
  `NSLock`-protected helpers.

- **Timing-flake thresholds don't mask regressions.** Run
  `swift test --filter "kotlinFileParses|elixirFileParses|timingSanity"`
  three times in a row; all bounds should pass with >10x headroom
  under normal machine load. A single failure on an idle machine
  means the threshold is too tight; three in a row means a real
  regression. Either way: file a backlog item, do not silently
  widen further.

### Ollama pane: MCP tool reachability (shipped 2026-04-20)

Round 5 of the `ollama-pane-discovery-models-bundle` umbrella. Pre-audit
showed the env-injection path is shared with the Terminal pane
(`TerminalViewRepresentable` merges the caller's env dict onto
`ProcessInfo.environment` before `startProcess`), and new
`Tests/SenkaniTests/PaneLaunchEnvTests.swift` pins the cross-type
parity — so we know the gate keys go in. What the unit tests cannot
cover: an external `ollama` binary actually answers, and a real MCP
client attached to the pane's session can reach `senkani_read` /
`senkani_session`. These soak steps close that loop.

- **Ollama daemon reachable, MCP env present.** Fresh project. Open
  the AddPaneSheet gallery → **AI & Models** → pick **Ollama**. With
  Ollama installed and its daemon running on localhost:11434 the
  pane should transition `Detecting… → connected` (green dot in the
  header) and start a terminal running `ollama run <default-tag>`.
  Expected env in that shell: `echo $SENKANI_PANE_ID` prints a UUID;
  `echo $SENKANI_PROJECT_ROOT` prints the project directory;
  `echo $SENKANI_OLLAMA_MODEL` prints the resolved tag (e.g.
  `llama3.1:8b`). Parity check: open a plain Terminal pane in the
  same workspace, dump the same three env vars — all three should
  be set on both panes; `SENKANI_OLLAMA_MODEL` is only present in
  the Ollama pane.
- **Senkani MCP tools answer from the Ollama pane.** From inside the
  Ollama pane's shell (either the `ollama` REPL's `!<cmd>` escape
  or quit back to zsh), run `senkani_read <anyfile>` via a connected
  MCP client (Claude Code, Cursor, or Codex). Expected: a non-empty
  response (outline-first by default). Re-run the same command from
  a plain Terminal pane — result should be equivalent shape (same
  file, same outline). Repeat with `senkani_session action=stats` —
  both panes should see the same session.
- **Ollama daemon absent.** Stop the daemon (`ollama stop` or
  `launchctl unload` the plist) and add a new Ollama pane. Pane
  should show the **Get Ollama / Retry** CTA (no terminal spawned).
  Clicking **Retry** after restarting the daemon should flip the
  pane to the connected-terminal state without recreating it.
- **`!<cmd>` escape inheritance (Schneier accepted-risk spot-check).**
  From inside the ollama REPL, type `!env | grep SENKANI_ | head`.
  Expected: SENKANI_* keys inherited (POSIX rule — the shell-out
  child inherits the REPL's env, which is the Terminal pane's env).
  This matches the Terminal pane's behaviour and is not a new leak
  path; confirming just documents the observation.

### Models pane: install → verify state machine (shipped 2026-04-20)

Round 4 of the `ollama-pane-discovery-models-bundle` umbrella. The Core
state machine is fully unit-tested with fake handlers + a planted HF
snapshot (see `Tests/SenkaniTests/ModelManagerInstallTests.swift`, 7
tests). What unit tests CANNOT cover: the MCP-registered verification
handler that calls `EmbedTool.engine.ensureModel()` /
`VisionTool.engine.ensureModel()` — that path pulls ~90MB–12GB from
HuggingFace and loads the real MLX `ModelContainer`. These soak steps
are the gate.

- **Happy path — MiniLM-L6.** Fresh install (delete
  `~/Documents/huggingface/models/sentence-transformers/all-MiniLM-L6-v2`
  first). Open the Models pane → click **Install** on MiniLM-L6.
  Expected: badge progresses `Available → Installing N% → Installed
  → Verifying… → Ready` with the linear progress bar filling during
  `Installing`. `senkani doctor` should afterwards print
  `✓ MiniLM-L6 Embeddings: verified`.
- **Happy path — Gemma 4 E2B** (lightest vision tier, ≥4GB RAM).
  Same flow. Expected: progress bar + auto-verify; `Ready` badge +
  trash button once the MLX container loads cleanly.
- **Delete + re-install round-trip.** On a verified model, click
  the trash icon. Expected: confirmation alert with `(N MB freed)`
  → click **Delete** → badge returns to `Available`, disk usage in
  the header drops. Click **Install** again → full state progression
  reaches `Ready`. Cache directory exists again on disk.
- **Failed verify retry.** Manually corrupt the config
  (`echo "{}" > ~/Documents/huggingface/models/<repo>/config.json`
  while `Ready`). Restart the app. Expected: `reconcileWithDisk`
  keeps it at `Downloaded` (config parses — the integrity check
  passes). Click **Re-verify** from the Ollama pane row (only shown
  when state is `broken` — to force `broken`, replace a weight file
  with zeros while in `Ready`; the MLX `ensureModel()` call should
  throw on weight-load). Expected: badge flips to
  `Verification failed`; the orange re-verify arrow appears; a
  second delete clears + re-install restores.
- **Offline install.** With Wi-Fi off, click **Install** on an
  un-cached model. Expected: badge flips to `Error` within a few
  seconds; the `lastError` copy in the alert banner is a network
  message. `senkani doctor` prints
  `✗ <model>: install error — <error>`.

**Carry-over: pre-existing URLProtocol-mock race (accepted risk).**
`MockURLProtocol.stubs` is `nonisolated(unsafe) static var [String: Stub]`
mutated from parallel swift-testing contexts. `swift test` on a clean
tree drops 3–8 flaky failures in
`RemoteRepoClient — network paths (URLProtocol stub)` and
`Bundle remote — URLProtocol paths` on busy CI workers. Running those
filters alone with `--filter RepoNetworkPath` shows the same races
(different tests fail depending on scheduling). NOT caused by this
round — grep shows the `@unchecked` storage pre-dates 2026-04. Fix:
wrap `stubs` in an `NSLock` or a `@_spi(Experimental) nonisolated(safe)`
actor. Left out of scope for this round; file a new backlog item for
an isolated fix.

### Ollama: curated LLM catalog + click-to-pull drawer (shipped 2026-04-20)

Round 3 of the `ollama-pane-discovery-models-bundle` umbrella. Unit
tests pin the pure-Foundation layer (curated-list invariants, pull
state machine, `ollama pull` output parser, `ollama list` tabular
parser, digest extraction, argv gating). The subprocess path
(`OllamaModelDownloadController`'s `Process()` spawn) is NOT
unit-tested — real `ollama` CLI isn't on the CI runner. These soak
steps are the gate.

- **Drawer opens from the pane header.** With Ollama.app running,
  add an Ollama pane (gallery or Welcome). Expected: header shows
  a `square.and.arrow.down` icon next to the `connected` dot.
  Click it: a 520×420 sheet appears with 5 model rows
  (Llama 3.1 8B, Qwen2.5 Coder 7B, DeepSeek-R1 7B, Mistral 7B,
  Gemma 2 2B). Each row shows name + tag + 1-line use-case +
  size. The row whose tag matches the pane's current default has
  an orange **default** chip.
- **Pull button discloses size BEFORE the click (Podmajersky).**
  Every un-pulled row's button reads **Pull N.N GB** — never a
  plain "Pull". Rows with models already on disk show
  **Current** (disabled) or **Use** (sets as default).
- **Click-to-pull streams progress.** On a row you haven't pulled,
  click the **Pull N.N GB** button. Expected: button swaps to
  **Cancel**, progress-line swaps from the size to a linear
  ProgressView + `XX% N.N GB`. Monitor Activity Monitor → an
  `ollama` child subprocess of SenkaniApp appears.
  On completion (~minutes depending on size + bandwidth), row
  flips to an **installed · <digest>** line with a green seal
  icon, button becomes **Use**.
- **Cancel mid-pull terminates the subprocess.** Start a pull,
  wait until progress reaches ≥5%, click **Cancel**. Expected:
  button returns to **Pull N.N GB**, progress-line returns to
  just the size, subprocess exits (gone from Activity Monitor
  within a second). `ollama list` at this point must NOT show the
  tag (partial pull got cleaned up).
- **Pulled digest matches `ollama list`.** After a successful
  pull, open Terminal.app and run `ollama list`. The digest
  shown in the drawer row (first 12 hex chars) must match the
  `ID` column for that tag. (This proves the parser + fallback
  list-parse chain wired correctly.)
- **Absent-state deep-links instead of pulling.** Quit Ollama.app,
  reopen the drawer (either via the pane header icon or by
  opening a fresh pane). Expected: every row's button reads
  **Install Ollama** (no size disclosed — pull is unreachable).
  Click one: the default browser opens `https://ollama.com/download`.
- **"Use" swaps the default + restarts chat.** With two or more
  tags pulled, click **Use** on a row that isn't the current
  default. Expected: default chip moves to the new row, the
  drawer stays open, and closing the drawer shows the pane's
  terminal has restarted (chat history cleared; the new model tag
  is the running session). The header model Menu also reflects
  the new selection.
- **Pull error surfaces cleanly.** Edge test: disconnect
  networking, start a pull. Expected: row state flips to
  **failed** with an orange warning icon + the truncated
  `ollama pull` error message (e.g. "Error: connection refused").
  Button returns to **Pull N.N GB** so the user can retry once
  connectivity is back.

**Environmental note (2026-04-20, FIXED in `filewatcher-fsevents-uaf`):**
The full-suite `swift test` flake originally filed as "SIGTRAP
(signal code 5) in the tree-sitter / MLX area" was misdiagnosed
on both counts. The actual signal was **11 (SIGSEGV)**, and the
faulting subsystem was the FSEvents `FileWatcher` — not
tree-sitter and not MLX. The crash got buffered into a neighbour
test's stdout line, which is what made it look like the parser
had killed the process; targeted `--filter` runs reordered the
test schedule and avoided the race entirely, which is why
`--filter Ollama` and `--filter PaneGallery` always stayed green.
Root cause was an `Unmanaged.passUnretained` use-after-free in
`Sources/Indexer/FileWatcher.swift::start` — FSEvents could fire
a callback on the watcher's serial queue while the watcher was
mid-`deinit`. Fix details + reproduction tests live under the
`filewatcher-fsevents-uaf` entry in `spec/autonomous-backlog.yaml`.
Post-fix: 6 consecutive `swift test --no-parallel` runs clean,
zero SIGSEGV, zero `non-zero retain count` warnings.

### Ollama: first-class `.ollamaLauncher` PaneType (shipped 2026-04-20)

Round 2 of the `ollama-pane-discovery-models-bundle` umbrella. Unit
tests pin the support layer (tag validator, launch-command builder,
resolve-with-fallback, default-tag invariants, gallery registration,
closed-port availability probe), but everything SwiftUI and
everything involving the real ollama daemon is manual.

- **Absent-state CTA.** Quit Ollama.app. Open SenkaniApp → add an
  Ollama pane (gallery → **AI & Models** → Ollama OR Welcome card
  → Start Ollama when no panes exist). Expected: after ~0.5 s the
  pane shows a `cpu` icon, `Ollama isn't running` headline, an
  orange **Get Ollama** button (opens https://ollama.com/ in the
  default browser), and a **Retry** button. Retry re-probes without
  tearing the pane down.
- **Connected state.** Start Ollama.app, wait for the tray icon to
  show active. In the pane, hit **Retry** (or add a fresh pane).
  Expected: `connected` status dot flips green, the terminal body
  spawns `ollama run llama3.1:8b` (the default tag), and the pane
  header shows the selected tag in a monospaced menu button with
  a dropdown caret.
- **Model switch restarts the session.** From the pane's header
  menu pick `gemma2:2b`. Expected: the running `ollama run …`
  subprocess tears down and a new one spawns with the new tag;
  the menu shows a checkmark next to `gemma2:2b`; pane context
  label in the outer header updates to the new tag.
- **Add-to-existing-project path.** Open an existing project with
  panes already present. Sidebar **+** → **AI & Models → Ollama**.
  Expected: pane lands on the active workstream like any other.
- **Persistence.** Pick a non-default tag, quit Senkani, relaunch.
  Expected: the pane reopens with your chosen tag, not the default.
- **MCP env passthrough (manual spot-check; formal verification is
  sub-item `mcp-in-ollama-pane-verify`).** In the running pane's
  terminal, hit Ctrl-D to drop back to a shell if ollama exits,
  then `env | grep SENKANI_`. Expected: `SENKANI_PANE_ID`,
  `SENKANI_PROJECT_ROOT`, `SENKANI_WORKSPACE_SLUG`,
  `SENKANI_PANE_SLUG=ollamaLauncher`, `SENKANI_OLLAMA_MODEL=<tag>`
  are all set. If `SENKANI_PANE_SLUG` is missing in the ollama
  subprocess specifically, file into sub-item `mcp-in-ollama-pane-verify`.
- **Welcome card vs gallery parity.** Delete all panes (fresh
  project), click the **Start Ollama** card on the Welcome
  screen. Expected: lands a first-class Ollama pane with the
  default tag — identical to the gallery path. The old
  `ollama run llama3` hardcoding should NOT appear anywhere
  (grep confirms at commit time, but the visual confirmation is
  here).
- **Accepted-risk follow-up.** Pane-open UI telemetry is NOT
  recorded in `token_events` this round (bounded-context gate;
  see the CHANGELOG for the reasoning). If you want a signal that
  the pane is being used before the dedicated UI telemetry path
  lands, count `~/.senkani/panes/*.env` files with
  `SENKANI_PANE_SLUG=ollamaLauncher` in them.

### Pane gallery: categorized add-pane sheet (shipped 2026-04-20)

Round 1 of the `ollama-pane-discovery-models-bundle` umbrella. Unit
tests pin the data model (17 entries, 4 categories, ≤6 per category,
filter behavior, regression pin for dashboard-present), but the
SwiftUI rendering is not covered by automated tests.

- **Visual render check.** Launch SenkaniApp → sidebar bottom bar →
  click "+ Add Pane" → choose "New Pane...". Expected: sheet at
  460×560 with four category section headers in order **Shell &
  Agents / AI & Models / Data & Insights / Docs & Code**, 2-column
  grid under each, every card shows icon + title + 1–2 line
  description. Dashboard must be visible under "Data & Insights"
  (regression pin; it was missing before this round).
- **Filter behavior.** Type "dash" — only the Dashboard card should
  remain, under just the "Data & Insights" header. Type "term" —
  only Terminal (Shell & Agents). Clear the filter — all four
  categories reappear.
- **Keyboard affordance (Butterick, accepted risk).** Tab through
  the sheet; every card should take focus in visual order. SwiftUI
  Button default focus ring is keyboard-reachable but visually
  subtle — verify it's still perceptible on the current theme. If
  the focus ring is invisible against the card hover state, file a
  follow-up for an explicit ring treatment.
- **Microcopy consistency (Podmajersky, accepted risk).**
  Descriptions are currently a mix of verb-first ("Run commands and
  AI agents") and noun-first ("Live preview .md files"). All are
  under 80 characters (pinned in tests) but the voice is
  inconsistent. A future microcopy audit round should normalize to
  one voice.
- **Regression check.** The Command Palette (⌘K) pane list should
  still show 17 entries (shared `PaneType` enum; the palette uses
  `CommandEntryBuilder` which is unchanged by this round). The
  sidebar's "+ Add Pane" Menu and its "Claude Code..." entry are
  also unchanged.

### Website-rebuild item 12 — Claude Design prototype extract (aborted 2026-04-20)

Autonomous round attempted `website-rebuild-12-claude-prototype-review`
and aborted per the item's own abort path: the share URL
`claude.ai/design/p/deee4b49-7dc6-48e7-bff1-5eb837dcad89?via=share` is
auth-walled (WebFetch returns HTTP 403 in a fresh non-interactive
context). The item was returned to `pending` status with this note; no
forward blocker exists (no other item lists it in `blocked_by`).

Operator action to unblock, pick ONE:

- **Option A — screenshots.** Open the share link in a logged-in
  browser, capture each screen of the prototype (landing + every
  sub-screen), drop the PNGs into a new
  `spec/autonomous/assets/claude-prototype/` directory, re-mark the
  backlog item `status: open`. The next autonomous round will
  extract visual ideas from the screenshots and file each accepted
  idea as a separate per-idea backlog item that closes by editing
  `assets/theme.css` or `docs/**/*.html` directly.
- **Option B — HTML/MHTML export.** From the logged-in share link,
  use browser "Save Page As… → Web Page, Complete" (or MHTML) and
  drop the export under
  `spec/autonomous/assets/claude-prototype-raw/`. The next round
  can parse the HTML offline.
- **Option C — drop the item.** If the prototype is no longer
  informing the rebuild (the umbrella shipped DELIVERED 2026-05-01
  without it), mark the item `status: skipped` in the backlog with
  a `## Skip note` body section and `mv` to `completed/2026/`. Item
  12 has zero downstream blockers.

### Phase S.1 — manifest schema + MCP tool gating (shipped 2026-04-20)

Foundation round of Phase S. The manifest file format and effective-set
resolution are fully exercised in unit tests, but the end-to-end story
(agent sees the filtered tool list, disabled-tool calls fail gracefully
with a usable message) can only be validated against a real Claude Code
session.

- **Empty-manifest backwards-compat.** In a fresh project, run Senkani
  MCP with **no** `.senkani/senkani.json`. Agent should see the full
  tool surface exactly as before — `senkani_read`, `senkani_exec`,
  `senkani_knowledge`, `senkani_web`, etc. all callable. If any tool
  is missing, the `manifestPresent: false` fallback broke.
- **Manifest present gates the advertised list.** Drop a
  `.senkani/senkani.json` with `{"mcpTools": ["knowledge"]}` into a
  project. Open a fresh MCP session — `ListTools` should return the
  four core tools (`read`, `outline`, `deps`, `session`) plus
  `knowledge`, and nothing else. The agent's tool palette confirms
  this (fewer tools visible).
- **Disabled-tool call returns Skills-pane pointer.** With the
  manifest above, ask the agent to run `senkani_exec` or
  `senkani_web`. Expected: `isError: true` with the text
  `"Tool '<name>' is not enabled in this project's manifest. Enable
  it in the Skills pane (or add it to .senkani/senkani.json)."` No
  silent dispatch, no crash.
- **User overrides layer correctly.** Add
  `~/.senkani/overrides.json` with
  `{"/abs/path/to/project": {"optOutTools":["knowledge"],"addTools":["exec"]}}`.
  Same project, fresh session: `knowledge` should disappear even
  though it's in the team manifest, and `exec` should work even
  though it isn't. Core tools stay visible.
- **Different project's overrides stay isolated.** The overrides
  file is a map keyed by absolute project-root path — confirm that
  adding an entry for a different project doesn't leak into the
  project under test. (Unit-tested, but worth spot-checking a real
  two-project setup.)
- **YAML migration pressure.** The spec calls for
  `.senkani/senkani.yaml`; this round ships JSON. Track whether any
  team that touches the manifest asks for YAML — if so, prioritize
  a Yams-backed follow-up round. Until then, JSON is the canonical
  on-disk format.

### Website redesign wave 2 — hero stack + /docs/ move (shipped 2026-04-19)

Second operator-directed round on the website. Three deliverables:
landing redesigned as a hero-per-major-feature stack (Apple-style),
all doc folders moved under `/docs/` to unpollute the root, and
font sizes bumped a tier across the board (nothing readable below
14px now). Wave 1's pending validations still apply; these are
additive.

- **Visual walk of the new landing.** Each hero is a full band with
  headline + bullets + CTA + custom illustration. Scroll the whole
  landing: does each band have visual identity? Do the alternating
  light/dark bands hold rhythm? Do the illustrations (before/after
  terminal, MCP grid, pane tiles, compound-learning flow, KB
  entity cards, security shield) read at a glance?
- **Every "Learn more →" link lands on its detail page.** Click
  through: Compression → `/docs/concepts/compression-layer/`. MCP
  intelligence → `/docs/reference/mcp/`. Workspace →
  `/docs/reference/panes/`. Compound learning →
  `/docs/concepts/compound-learning/`. KB →
  `/docs/concepts/knowledge-base/`. Security →
  `/docs/concepts/security-posture/`.
- **Root cleanup verification.** `ls` the repo root — you should
  see `index.html`, `assets/`, `docs/`, `scripts/`, plus code/spec
  dirs. No more `/concepts/`, `/reference/`, `/guides/`, `/status/`,
  `/about/`, `/changelog/`, `/what-is-senkani/` at root.
- **Font sanity pass.** Every block of reading text should be
  ≥14px; reference tables ≥15px; code blocks ≥15px; badges + tags
  ≥13px. Put your face close; do captions, meta rows, source
  pointers, search hit paths, code-copy buttons all read
  comfortably?
- **Subpath deploy sanity.** The relative-paths architecture now
  spans an extra depth level (most pages moved from depth 1 → 2,
  deep refs from 3 → 4). Push to a preview branch, enable GH Pages,
  confirm `ckluis.github.io/senkani/` loads the landing + that
  `ckluis.github.io/senkani/docs/reference/mcp/senkani_read/` also
  loads its CSS/JS correctly.
- **Mobile narrow-width heroes.** At 360–600 px, each product-hero
  should collapse to single-column, visual below text, bullets
  still readable, the CTA still prominent. Check each of the 6
  feature heroes.
- **Contrast on dark hero bands.** Heroes 2 (MCP) and 5 (KB) are
  dark (`--ink` background, `--bg` text). Verify WCAG AA on copy,
  bullet check marks, the "Learn more →" CTA (accent-hi on ink),
  and the illustration tiles.

### Website rebuild — visual + a11y validation (shipped 2026-04-19)

The full github-pages rebuild landed in one operator-directed round
(umbrella `website-rebuild-0-spec` + items 1–9). 94 HTML files across
a Diátaxis-structured wiki: 19 MCP tool pages, 19 CLI command pages,
17 pane pages, 10 option pages, 7 concept pages, 9 guide pages, plus
10 hub pages and a rewritten landing. Everything deploys from the
repo root via GitHub Pages with `.nojekyll` present; all internal
paths are relative so it works both over `file://` and at
`ckluis.github.io/senkani/`. Automated a11y tooling wasn't run in the
round — needs a real machine with Node / axe-core-cli available.

- **Visual inspection on a mid-tier display.** Open <code>index.html</code>
  via `python3 -m http.server 8080` (NOT `file://` — relative paths
  now work there, but some browsers block `fetch()` on `file://`).
  Skim hero, positioning, teasers, stat strip, gallery. Look for:
  unreadable text, broken cards, broken dark-mockup legibility,
  misaligned grids, missing spacing.
- **Nav sanity walk.** Click through: Home → What is it? →
  Concepts → each concept page → Reference → MCP tools index →
  `senkani_read` → `senkani_web` → Options → FCSIT → Terse →
  Guides → Install → Troubleshooting. Every breadcrumb, every
  wiki-nav entry, every "see also" link should resolve without
  404s.
- **axe-core-cli pass on every page.** Install via `npm i -g
  @axe-core/cli` and run: `axe http://localhost:8080/ --exit`,
  then spot-check a representative deep page
  (`axe http://localhost:8080/reference/mcp/senkani_read/`).
  Target: 0 AA violations per page. If anything fires, update
  `assets/theme.css` tokens and re-run.
- **Lighthouse perf + a11y per page.** Open Chrome DevTools →
  Lighthouse → run against landing + one deep reference page.
  Target: perf ≥ 90 (mid-tier), a11y ≥ 95. The biggest drag is
  the Google Fonts stylesheet; `preconnect` is in place but if
  perf misses, consider `font-display: swap` hints or self-
  hosting.
- **Mobile (360–780px) layout.** Open any page in devtools
  mobile mode. The hamburger menu should work; wiki-nav should
  collapse to a stacked list above content; the hero type should
  scale sanely; the tool listing should reflow to single-column.
- **Keyboard-only traversal.** Tab through the landing. Skip-link
  should be the first focusable element. Every link/button should
  show the orange focus ring. Nothing trap-focused.
- **Legacy anchor redirects.** Hit
  `http://localhost:8080/#how-it-works` — should redirect to
  `/concepts/`. Same for `#mcp-tools` (→ `/reference/mcp/`),
  `#install` (→ `/guides/install/`), `#terse` (→
  `/reference/options/terse/`). See `assets/app.js` legacyMap.
- **Search: live Lunr index.** `website-rebuild-10-search` shipped
  2026-04-20 (see CHANGELOG). Type into the top-nav search. On the
  first keystroke the network panel should show `lunr.min.js`
  (~29 KB) and `search-index.json` (~85 KB) fetched. Subsequent
  queries should not re-fetch. Try: `read` → `senkani_read · MCP
  tool reference` top. `bench` → `senkani bench · CLI reference`
  top. `install` → the guide page top. Arrow keys should highlight
  rows; Enter should navigate; Escape should close. The global
  `/` hotkey should focus the nav search from any page. Known
  2-char ambiguities to spot-check: `re` picks one of read/repo,
  `ex` picks one of exec/explore/export, `pa` picks one of
  pane/parse, `se` picks one of search/session/setup — both pages
  should appear in the top 3 regardless.
- **Deploy preview.** Push to a branch, enable GitHub Pages for
  that branch, open `https://ckluis.github.io/senkani/`. All
  relative paths should resolve under the `/senkani/` subpath.
  Confirm CSS loads, deep links work, external GitHub links
  still go to `github.com/ckluis/senkani`.
- **Safari + Firefox cross-browser.** Every page built + tested
  in Chrome by default; Safari/Firefox should just work since
  there's no exotic CSS, but confirm. Especially mockup chrome
  (mockup gradients, pane dots, FCSIT button pills).
- **`prefers-reduced-motion`.** Toggle macOS Reduce Motion →
  reload landing. Terminal-cursor blink in the hero mockup
  should stop; smooth-scroll should disable. Both are in
  `assets/theme.css`.

### `senkani uninstall` — real-install validation (synthetic smoke shipped 2026-04-19; release-checklist home shipped 2026-04-26)

> **Canonical home: `spec/autonomous/backlog/release-v0-3-0-uninstall-pass-*.md`**
> (operator-local; the spec tree is gitignored). That backlog item
> is the per-release uninstall validation checklist (the original
> A1–A6 surface — six checks, real-install required) — closed by
> appending pass/fail/note lines to its acceptance bullets and
> moving it into `completed/<YYYY>/`. Each minor-version bump opens
> a fresh `release-v<X.Y.0>-uninstall-pass` item. The wave entry
> below stays as the rolling diary for ad-hoc runs that aren't
> tied to a release.

`Tests/SenkaniTests/UninstallSmokeTests.swift` fences the
discovery + filter + removal logic against a fixture HOME (6 tests).
That covers refactor-induced regressions. What synthetic tests
*can't* catch: a newly-added runtime artifact path that the scanner
doesn't know about yet. So the real-install pass still matters:

- **Run `senkani uninstall` on a real dev install.** With a Senkani
  app that has actually been registered (MCP entry in
  `~/.claude/settings.json`, hooks in project settings, something in
  `~/.senkani/`, optionally a launchd plist from `senkani schedule`).
  Default run (no flags) — confirm the artifact list shows only the
  categories you expect, cancel with `N`, verify nothing on disk
  changed.
- **`senkani uninstall --keep-data`.** Verify the list omits the
  session database line; re-run, accept, confirm that
  `~/Library/Application Support/Senkani/` survives while the other
  six categories go.
- **`senkani uninstall --yes` (full wipe).** Run twice. First run
  removes everything the scanner found; second run prints "Nothing
  to uninstall" (idempotent). `claude` in a plain terminal should
  show no Senkani tools. Re-launching SenkaniApp should re-register
  everything (reversibility).
- **Look for artifacts the scanner missed.** After a `--yes` run, do
  a quick sweep: `ls ~/.senkani/`, `ls ~/Library/LaunchAgents/com.senkani.*`,
  `grep -l senkani ~/.claude/settings.json ~/.claude/projects/*/settings.json`,
  `ls ~/Library/Application Support/Senkani/`. If anything is still
  there, file a note — that's a new category the synthetic fixture
  needs to grow to cover.

### PaneDiaryInjection — round 3 of pane-diaries (shipped 2026-04-19, umbrella DELIVERED)

Round 3 wires generator + store into the MCP subprocess (read on
server start, write on shutdown) and sets the workspace/pane slug env
vars in SenkaniApp. Everything below the process boundary is unit
tested — what unit tests can't exercise until a real session runs end-
to-end:

- **Actual "reopen a terminal in the same project" UX.** Launch
  SenkaniApp, open a terminal pane in a project (say
  `~/Desktop/projects/senkani`), run `claude` or a few tool calls so
  token_events accumulate, close the pane (or quit the app). Reopen
  the pane. The MCP subprocess spawns with
  `SENKANI_WORKSPACE_SLUG=projects-senkani` +
  `SENKANI_PANE_SLUG=terminal`; its `instructionsPayload` should now
  include a `Pane context:` section summarizing the last session's
  last command, files touched, token cost, and recent commands. Check
  the MCP server stderr around startup for the line printed by the
  payload, or inspect the on-disk diary at
  `~/.senkani/diaries/projects-senkani/terminal.md`.
- **Multi-terminal collision inside one workspace.** Open two terminal
  panes in the same project. Both spawn with the same pane-slug
  (`terminal`) — intended behavior, per the cross-session-slot design
  — so their close events write the SAME diary file. Verify the
  last-closed pane's content wins (current diary reflects whichever
  pane shut down last). If this feels wrong in practice, file a
  backlog item to include an index suffix in the slug (e.g.,
  `terminal-1` / `terminal-2`). Left as an intentional trade-off for
  now: diaries are a "resume the slot" hint, not a "resume exactly
  this pane instance" guarantee.
- **Disk permission failure on pane close.** Remove write on
  `~/.senkani/diaries/` (`chmod -w`). Close a terminal pane. The MCP
  shutdown should NOT hang — `PaneDiaryInjection.persist` swallows
  the throw and moves on to `endSession` normally. Confirm via
  process exit latency (should be the usual <500 ms) and MCP stderr
  (no unhandled throws).
- **Slug edge cases in real workspaces.** Open panes in projects
  whose working directories contain `..` resolution, symlinks, or
  unusual chars (spaces, parentheses, emoji). The slug helper in
  PaneContainerView strips `..` + backslashes before joining; confirm
  the resulting env var works end-to-end (diary file lands at the
  expected path). If a project path produces an empty slug, the
  helper falls back to `"workspace"` — verify that too if you've got
  an exotic dev dir.
- **SENKANI_PANE_DIARY=off mid-session.** Export the env and relaunch
  SenkaniApp. Confirm (a) no new diaries are written on pane close
  and (b) existing diaries are not injected on pane open. Flip the
  env back off (unset), relaunch, confirm behavior returns.

### PaneDiaryGenerator — round 2 of pane-diaries (shipped 2026-04-19)

The composition half lands standalone — no callers yet. Round 3 wires
the DB fetch (pane-slug → session_ids → `[TimelineEvent]`) and the
pane-open MCP injection. What unit tests can't exercise on a real
install until round 3 arrives:

- **Real-row token budget realism.** Unit tests assert the hard
  200-token cap with synthetic rows. On a real install with 100+ real
  `token_events` rows carrying real filenames and argv strings, visually
  confirm the produced brief reads like a useful resume note rather
  than a truncated data dump. Eyeball: last command is meaningful,
  `Files:` basenames are recognizable, `Cost:` total reflects real
  activity, `Recent:` doesn't trail off awkwardly.
- **Unicode / wide-char content.** Rows whose `command` column holds
  CJK / emoji / RTL text should land in the brief without breaking
  the 4-bytes-per-token estimator's actual byte count. Run
  `PaneDiaryGenerator.generate` (via a small harness once round 3 is
  in, or via Swift REPL now) on a fixture with mixed scripts; confirm
  the output is still ≤200 tokens by the `ModelPricing` definition.
- **Caller-supplied error formatting.** The generator renders any
  `lastError: String?` verbatim (truncated at 140 chars). Round 3
  callers should pass a pre-cleaned one-line summary — if they pass
  the raw SQLite error message or a multi-line stack trace, the brief
  will contain linebreak garbage that the section-labeled format
  can't parse. Sanity-check the round-3 error-derivation code once
  it lands.

### PaneDiaryStore — round 1 of pane-diaries (shipped 2026-04-19)

The I/O half lands standalone — no callers yet. Round 2
(`PaneDiaryGenerator`) and round 3 (pane-open MCP injection + pane-close
regen) will produce the real user-visible behavior. What unit tests
can't exercise on a real install:

- **File permissions under a real umask.** Test `writtenFileIsMode0600`
  asserts `chmod(2)` lands, but it runs inside a tempdir with no
  umask surprises. On a real `$HOME` with an unusual umask
  (0077 / 0022 / 0002 variants), confirm a fresh diary
  (`~/.senkani/diaries/<ws>/<pane>.md`) reports `-rw-------` under
  `ls -l`, not `-rw-r--r--` or `-rw-rw-rw-`.
- **Multi-FS rename edge.** `replaceItemAt` is atomic on a single
  filesystem; if a user's `$HOME` is on an exotic mount (tmpfs,
  encrypted overlay, symlinked into APFS snapshot), confirm
  write+read round-trip still works without the tmp file left behind.
  `ls -la ~/.senkani/diaries/<ws>/` after a fresh write should show
  only `<pane>.md`, no `.pane.md.tmp.<pid>` stragglers.
- **Env gate flips cleanly mid-session.** Set `SENKANI_PANE_DIARY=off`
  in the launch env of a senkani daemon that already wrote diaries.
  Start the daemon, write a diary via a future direct caller (or the
  round-3 MCP path once it lands). Expect no disk writes and no reads
  surfaced into the pane-open brief. Flip the env back (relaunch),
  confirm old diaries are still readable and the feature is enabled.
- **Redaction of novel secret patterns.** Paste a hand-authored secret
  style that the current `SecretDetector.patterns` set doesn't cover
  (e.g., an internal-format token) directly into a diary on disk.
  Trigger a read. Confirm the read returns the raw token (as expected
  — redaction only catches known patterns). File a backlog item to
  extend `SecretDetector.patterns` if the internal format is common
  enough to warrant a regex.
- **Slug stability across pane-id recycles.** Round 3 will wire the
  actual pane-slug derivation from `PaneType` + workspace slot.
  Until then, the I/O layer takes the slug as a caller-supplied
  string; no real-machine test is possible for round 1. Defer the
  "reopens-same-slot produces-same-diary" behavioral check to round 3.

### Sprint Review pane (shipped 2026-04-19)

Unit tests cover the view-model routing (accept/reject dispatch per
artifact kind, window filter, staleness flag mapping, file side effects
for context doc + workflow playbook). What they cannot exercise is the
SwiftUI pane end-to-end in a running SenkaniApp:

- Launch SenkaniApp. Open ⌘K. Filter by "sprint". Expect a
  "New Sprint Review" row under Panes. Hit enter — a new Sprint
  Review pane lands in the active workstream. Also verify
  "+" toolbar button → "Sprint Review" card in the grid.
- On an install with no staged compound-learning artifacts, expect
  the empty state ("No staged proposals") with the secondary line
  about the daily sweep promoting from `.recurring`. No errors.
- Populate staged artifacts via the CLI (or run a real session to
  seed them). Reopen the pane. Expect four sections collapsed by
  kind, each row showing title + subtitle + confidence pill + `×N`
  recurrence. Adjust the window stepper (7d / 14d / …); the visible
  row set should narrow/widen per the `lastSeenAt` cutoff.
- Click Accept on a filter-rule row. Expect: row disappears
  (status → applied). No filesystem change. `senkani learn status`
  from the CLI confirms the transition.
- Click Accept on a context-doc row. Expect: row disappears, a
  new `<projectRoot>/.senkani/context/<slug>.md` lands on disk.
  Open it — body matches the staged body. A second open of the same
  pane after a session should show the doc surfacing through
  SessionBriefGenerator.
- Click Accept on a workflow-playbook row. Expect:
  `<projectRoot>/.senkani/playbooks/learned/<slug>.md` lands on
  disk. Content matches.
- Click Accept on an instruction-patch row. Expect: state-only
  transition (no file write — instruction patches are
  Schneier-constrained).
- Click Reject on any row. Expect: row disappears, status →
  .rejected. Re-rejecting via `senkani learn reject <id>` is a no-op.
- Trigger an error path — delete `~/.senkani/learned-rules.json`
  mid-click, click Accept. Expect: orange error banner with
  `Accept failed: …`. Dismissing the banner via × clears it. Pane
  remains interactive.
- Fire a quarterly audit in the absence of any applied artifacts
  (clean install). Expect: the "Stale applied artifacts (N)"
  section is hidden. With stale artifacts present (e.g. an applied
  filter rule with `lastSeenAt` back-dated > 60 days), the section
  renders with amber accents and a Retire button per row.
- Confirm the `liveToolNames` default — in the current wiring, the
  pane passes an empty `Set<String>`, so the quarterly audit skips
  the instruction-patch-tool-missing heuristic. If the operator
  decides to wire this to `ToolRouter.allTools().map(\.name)` from
  SenkaniApp (requires cross-process state the GUI doesn't have
  today), a new manual-log entry will supersede this one.

### Browser Design Mode — click-to-capture wedge (shipped 2026-04-18)

Unit tests cover the pure logic (selector generation, Markdown schema,
state machine, SecretDetector sink passes). What they cannot exercise
is the actual WKWebView + WKUserScript + clipboard + NSEvent flow in a
running SenkaniApp. Real-session sanity checks:

- Launch SenkaniApp with `SENKANI_BROWSER_DESIGN=on` in the
  environment. Open a Browser pane on a real site (e.g.
  https://developer.mozilla.org/en-US/docs/Web/HTML/Element/button).
  Press ⌥⇧D. Expect: the URL-bar indicator flips to orange; cursor
  becomes a crosshair when hovering the web content; hover outlines
  elements with a 1px amber border. Press ⌥⇧D again OR Escape —
  the mode exits, indicator goes gray.
- With mode on, click a `<button>` element. Expect: a ~2s toast at
  the top of the pane ("Captured <selector> — copied to clipboard.");
  paste into any other editor and verify the Markdown schema —
  `## Browser element (senkani design mode)` header, `selector`,
  `tag`, `text`, `captured: <ISO8601>` lines. Verify the text is
  truncated at 300 chars on a long-text element.
- Navigate the webview to a different URL while Design Mode is on.
  Expect: the URL-bar indicator flips back to gray (mode exited);
  no toast persists; subsequent click does NOT capture. Confirms the
  WKUserScript + message handler were removed on navigation (guards
  Torvalds' leak-across-navigation flag).
- Find or build a page with a shadow-DOM component (e.g. a custom
  element using `attachShadow({mode:'open'})`) and click something
  inside. Expect: the toast reads "Can't capture — element is
  inside a shadow DOM." — not a malformed capture. Verify
  `senkani stats events` shows `browser_design.shadow_dom_skipped`
  incremented.
- Close the Browser pane while Design Mode is on. Expect: no crash,
  no lingering mode on the next opened Browser pane. Verify
  `~/.senkani/events.log` (or whatever surface is plumbed) shows the
  three recorded counters (`entered`, `captured`,
  `shadow_dom_skipped`) and that `keyboard_conflict` is NOT recorded
  from routine use — it's declared but the Swift NSEvent monitor
  runs out-of-band from page JS so it never increments in practice.
- Clipboard sanity: with Design Mode on, capture an element, then
  immediately hit ⌘C (system Copy) with text selected elsewhere.
  Expect: ⌘C overwrites our capture. This is expected — we write
  to the standard pasteboard; system Copy wins. Worth confirming so
  the UX isn't surprising.
- Keyboard guard: with Design Mode NOT installed (env var unset),
  press ⌥⇧D inside a Browser pane. Expect: no-op, no WKUserScript
  installs, no `entered` counter. The env gate is what makes this a
  default-off wedge.

### Budget enforcement — dual-layer symmetric tests (shipped 2026-04-18)

Unit tests now cover both the MCP gate (`session.checkBudget()`) and
the hook gate (`HookRouter.checkHookBudgetGate`) symmetrically via the
new `BudgetConfig.withTestOverride` + injectable cost closures. These
are pure-function tests — they don't exercise the real budget
`~/.senkani/budget.json` on disk or the real
`SessionDatabase.costForToday()` query. Real-session sanity checks:

- Configure a real `~/.senkani/budget.json` with a low daily cap
  (say $0.50). Run Senkani for a session that crosses the cap. Verify:
  (1) MCP tool calls return `"Budget exceeded: Daily budget …"` with
  `isError: true`; (2) non-MCP Read/Bash/Grep via the hook relay
  return `permissionDecision: deny` with the same reason string.
  The CHANGELOG text is the contract — if Claude Code sees a
  different message for the same condition across the two paths,
  flag it.
- With the same config, confirm the 80% soft-limit warning surfaces
  on MCP tool calls with a `[Budget Warning]` prefix but still
  executes the tool — and does NOT surface on the hook path (hook
  gate only has block/passthrough today, no warn prefix).
- Pane-cap path: set `SENKANI_PANE_BUDGET_SESSION` in a pane env,
  exceed it. MCP tool calls should block with a "Pane session
  budget exceeded" message. Non-MCP hook-routed tools in the SAME
  pane will NOT block on the pane cap (by design — pane cap is
  MCP-session-scoped; the asymmetry is encoded in
  `checkHookBudgetGate` passing `sessionCents: 0`).

### SkillScanner — scanAsync() wired into Skill Browser (shipped 2026-04-18)

Unit tests cover the async dispatch (Task.detached priority .utility),
fixture-root parity with sync scan, and a timing-sanity upper bound.
Real-machine validation — specifically to confirm the UI no longer
stalls on large home directories — can only be done in the running app:

- Seed or confirm presence of a non-trivial `~/.claude/` tree
  (≥ 50 command files + several nested SKILL.md subdirectories — the
  author's machine has ≈ 120 commands + 40 skills, which stalls the
  old sync path visibly). Open Senkani → Skill Browser pane. The
  "Scanning for skills…" spinner should appear smoothly (no frozen
  window title-bar, no beachball) and resolve within ~1 second on
  modern hardware. Hover the window chrome and drag during the scan —
  the main thread must remain responsive; pre-fix this dragged only
  after the scan completed.
- Click the Rescan button with the same tree. Spinner → list refresh
  cycle should feel identical to initial load. No duplicate entries,
  no stale flicker of the previous list.
- Point Senkani at a machine with a dotfile tree that symlinks back
  into itself (historically rare but possible via
  `~/.claude/commands/mirror -> ~/.claude`). The existing symlink
  loop guard in `scanRecursive` should still terminate; scanAsync
  must return the deduped result without blocking the UI.
- Regression guard: If the Skill Browser ever starts feeling sluggish
  again, grep for `SkillScanner.scan()` (no args) in `SenkaniApp/`.
  A deprecation warning should already fire at build time; this
  check is the "operator sanity" version.

### Display settings — font-family picker + persistence (shipped 2026-04-18)

Unit tests cover the pure `Core.PaneFontSettings` type (clamp, resolve,
diff). The AppKit resolution path (`NSFont(name:size:)` →
`monospacedSystemFont` fallback) and the live view update happen in
`SenkaniApp` which the test target cannot import. Real-machine
validation to run next session:

- Open Senkani, pick a terminal pane, open the gear → Display section.
  Confirm the font-family Picker lists all six curated names (SF Mono,
  Menlo, Monaco, Courier, Courier New, Andale Mono) and the current
  selection is highlighted. Switch between them — the terminal view
  must redraw glyphs immediately with no restart.
- Move the size slider one tick at a time (9 → 10 → 11 …). Each tick
  should fire exactly one font re-apply; multiple ticks in rapid
  succession should not produce visual tearing.
- Pick Monaco, quit Senkani, relaunch. The pane should come back with
  Monaco. Pick a size (e.g. 15pt), quit, relaunch — size persists.
- Simulate a missing font: tamper `~/.senkani/workspace.json` to set
  `"fontFamily": "BogusFont"`. Relaunch — the pane must revert to SF
  Mono cleanly (no crash, no blank terminal). `clampFontSize` and
  `resolveFamily` run at restore time.
- Edge case: set `fontFamily` to `"Courier New"` on a clean machine
  install. If the name resolves via `NSFont(name:size:)`, it renders
  Courier New; if not, the AppKit fallback silently uses
  `monospacedSystemFont`. Verify visually that the terminal is never
  blank.

### Pane IPC socket migration (shipped 2026-04-18)

`MCPSession.sendBudgetStatusIPC` now writes to `~/.senkani/pane.sock`
instead of `~/.senkani/pane-commands.jsonl`. The GUI wires
`SocketServerManager.shared.paneHandler` from `ContentView.onAppear`.
Unit tests exercise the helper against a temp-UDS listener and prove
9 wire-format + lifecycle invariants, but the full production loop
needs a real machine run:

- Open Senkani, spawn a Claude pane, set `SENKANI_PANE_BUDGET_SESSION`
  low enough that a few tool calls cross the soft-limit. Confirm the
  amber triangle badge lights up in the pane header via the socket path
  (not the old JSONL file). `~/.senkani/pane-commands.jsonl` must NOT
  be created or appended to — verify with `stat` before + after.
- Push the pane over the hard limit. Confirm the red block badge
  appears with `$spent/$limit` text. Budget status must clear on pane
  restart.
- `senkani_pane list` via the MCP tool from a Claude session. Pre-fix
  this path was broken (paneHandler was unset; the listener returned
  "No pane handler registered"). Post-fix it should return the JSON
  pane list within <10ms.
- Confirm `SENKANI_SOCKET_AUTH=on` path still works end-to-end —
  handshake frame + command frame must both land before the server
  dispatches.

### Schedule timeline integration (shipped 2026-04-18)

`Schedule.Run` now emits `token_events` rows at start / end / blocked
points of every scheduled fire so runs render in the Agent Timeline
pane. Unit tests cover the helper (event shape, session-id pairing,
project-root filtering, blocked-without-pair, runId format) against a
temp DB, but several display + persistence paths only exercise under a
real launchd fire + live `SessionDatabase.shared`:

- [ ] **End-to-end timeline render.** Create a schedule (e.g.
      `senkani schedule create --name tl-smoke --cron '*/2 * * * *'
      --command 'echo hi'`), wait for it to fire, then open the Agent
      Timeline pane in the app and confirm a `schedule_start` row and a
      `schedule_end` row appear with `command` values of
      `"tl-smoke: echo hi"` and `"tl-smoke: success"`.
- [ ] **project_root correctness under launchd.** launchd's default cwd
      is `$HOME`; `Schedule.Run` uses `FileManager.currentDirectoryPath`
      as the event's `project_root`. Confirm the Timeline pane's
      project filter correctly surfaces (or hides) the scheduled-run
      events depending on which project is active. If the event
      reliably files under `$HOME` only, consider a follow-up to wire
      `WorkingDirectory` through the plist (already on the queue
      below) so the events land under the source repo instead.
- [ ] **Budget-block path visibility.** Configure a zero-dollar daily
      cap in `~/.senkani/budget.json` and a task with
      `--budget-limit-cents`. Wait for a fire. Confirm a single
      `schedule_blocked` event appears in the Timeline with the block
      reason embedded in `command` (e.g. `"task: budget_exceeded
      (Daily budget exceeded: $0.00 / $0.00)"`) — and that NO
      `schedule_start` or `schedule_end` pair is present for the same
      run.
- [ ] **Failed-run exit code visibility.** Create a schedule with
      `--command 'exit 7'`. Wait for a fire. Confirm the Timeline
      `schedule_end` row's `command` is `"task: failed: exit 7"` and
      the corresponding `schedule_start` row exists with the original
      command text.

### Schedule worktree spawn (shipped 2026-04-18)

`senkani schedule create --worktree` opts a cron job into running in a
fresh detached-HEAD git worktree under
`~/.senkani/schedules/worktrees/{name}-{runId}/`. Unit tests cover the
helper (create / cleanup / retain-on-failure / concurrent-spawn /
non-git-repo rejection / run-id shape) hermetically, but several
end-to-end paths only exercise under a real launchd fire:

- [ ] **Real launchd fire with `--worktree`.** Create a schedule with
      `senkani schedule create --name wt-smoke --cron '*/2 * * * *'
      --command 'git rev-parse HEAD > /tmp/senkani-wt-smoke.out' --worktree`
      from inside a real git repo. Wait two minutes. Confirm the `.out`
      file exists, the HEAD it captured matches the source repo's HEAD,
      and that no worktree dir remains under
      `~/.senkani/schedules/worktrees/` after a clean run.
- [ ] **Retain-on-failure path.** Change the command to `false` so the
      shell exits non-zero. After the next fire, check that the
      worktree dir is retained for inspection and that the stderr log
      (`~/.senkani/logs/{name}.err`) includes the
      `Worktree retained for inspection: …` line with the path.
- [ ] **Cwd inheritance via launchd.** By default launchd starts jobs
      with cwd = `$HOME`, so `--worktree` fails fast with notGitRepo
      unless the user's `$HOME` is itself a git repo. Confirm the
      `lastRunResult` in the saved task JSON reads
      `failed: Not a git repository: …` in that default-cwd case, and
      document whether we should add a `WorkingDirectory` key to the
      generated plist in a follow-up.
- [ ] **TTL cleanup for retained worktrees.** This round explicitly did
      NOT ship automatic TTL-based cleanup of retained failure worktrees
      — they accumulate until the operator manually deletes them. Track
      how many build up over a real week of schedule failures; if it's
      non-trivial, add a `.ttl_days` config knob in a follow-up round.
- [ ] **Branch pollution check.** The helper uses
      `git worktree add --detach` (no new branch), so branches shouldn't
      accumulate — confirm `git branch -a` stays clean after ~10 fires.

### Tree-sitter grammars — Dart, TOML, GraphQL (shipped 2026-04-18)

Indexer now covers 25 languages (was 22). 10 unit tests validate parse +
symbol extraction for each. Real-world items to exercise on the operator
machine:

- [ ] **Index a real Flutter / Dart repo.** Point Senkani at a
      non-trivial Dart codebase (e.g. a `pubspec.yaml` project with
      multiple classes, mixins, extensions, getters/setters) and call
      `senkani_search`, `senkani_outline`, `senkani_explore` on Dart
      files. Confirm classes, methods, enums, and mixins show up with
      correct container resolution and line numbers.
- [ ] **Parse a production `Cargo.toml` / `pyproject.toml`.** Run
      `senkani_outline` on both. Verify that top-level pairs emit as
      `.variable` and `[table]` sections become `.extension` with their
      nested pairs as `.property`. Double-check that `[dependencies]`
      nested tables don't lose their container.
- [ ] **Parse a real schema.graphql.** Pick a production GraphQL schema
      (Hasura, Supabase, or any app's `schema.graphql`). Confirm that
      `senkani_outline` lists every top-level `type`, `interface`,
      `enum`, `scalar`, `union`, `input`, and `directive`. The
      `walkGraphQL` path is a second walker (not the main `walkNode`
      switch) so the one thing to watch for is missed node types.
- [ ] **Swift 6 codegen watchdog.** Run `swift test --no-parallel` on a
      machine with a different Xcode / Swift toolchain version (not
      just the one this round was built on). Two cases in `walkNode`
      that call back into itself are deliberately folded into a single
      `case "A", "B":` to dodge a Swift-6 switch-codegen cliff; on a
      different toolchain the cliff may be somewhere else. If Bash
      realistic-script tests SIGBUS, that's the smell.

### Migration race test + flock inode fix (shipped 2026-04-17)

3 unit tests (`MigrationMultiProcTests`) spawn two `senkani-mig-helper`
processes via `Foundation.Process` and exercise the cross-process flock
contract automatically. Fixed a real defect in `MigrationRunner.run`
along the way (pre-racing `FileManager.createFile` + `open(O_RDWR|
O_CREAT)` → different inodes per process → no mutual exclusion). Real-
world validation items — mostly redundant now that the contract is
under unit test, but worth a once-over after the first real session
that triggers a migration:

- [ ] **Real install + upgrade migration on a DB with actual data.**
      Run the new build against an existing user DB (committed through
      months of real sessions, not a fresh `/tmp` fixture). Confirm
      `schema_migrations` is populated, `PRAGMA user_version` matches
      the max shipped version, no `.schema.lock` written, and no
      surprise lockfile left behind from an older install.
- [ ] **Concurrent launch: MCP server + GUI app on one DB.** Start
      the MCP server and the GUI workspace at roughly the same time,
      both pointing at the same user DB. Verify (via the schema
      migration logs in `stderr`) that exactly one side applies any
      pending migrations and the other sees them as already applied.
      Pre-fix this would have raced; with the fix it's the same
      contract the unit test now exercises.
- [ ] **Kill-switch lockfile user-visible path.** Force a migration
      failure (e.g. point a dev build at a DB where a future
      migration is rigged to fail) and confirm the error message
      surfaced to the user mentions the `.schema.lock` path and the
      "investigate the DB and remove the lockfile before retrying"
      guidance.

### MLX inference serialize lock (shipped 2026-04-17)

7 unit tests cover the lock primitive (non-overlapping concurrent exec,
FIFO ordering, error-in-closure releases the lock, unload-handler
register + fire on simulated warning, `clearUnloadHandlers` empties the
registry, `startMemoryMonitor` idempotent / stop clears, queue-depth
drains). The DispatchSource memory-pressure path can't be faked in a
unit test — it only fires under real kernel-reported RAM pressure.
Real-world validation items:

- [ ] **Concurrent vision + embed under real MLX.** Open two panes,
      fire `senkani_vision` on a screenshot in one and `senkani_search`
      (which warms the embedding model) in the other within a few
      hundred ms. Confirm both complete without `EXC_BAD_ACCESS` or
      Metal-pool stalls, and that stderr shows the calls did not
      interleave their "vision model loaded" / "indexed N files" log
      lines.
- [ ] **Memory-pressure unload.** Load a Gemma 4 tier (trigger any
      `senkani_vision` call), then deliberately pressure memory —
      `memory_pressure -s 10 -l warn` or spawn a large process — and
      watch stderr for the next `senkani_vision` call re-loading the
      model from scratch. If RAM dropped below the loaded tier's
      `requiredRAM`, confirm the re-load picks a smaller tier from the
      fallback chain.
- [ ] **No regression on single-caller latency.** Run a baseline
      `senkani_vision` analysis; add `MLXInferenceLock` warmup (call
      once, let it release); re-run; confirm the serialized path adds
      <1 ms of lock overhead vs. the pre-lock path (eyeball the
      per-call total; the lock is pure actor work so it should be
      sub-millisecond).

### DiffViewer LCS (shipped 2026-04-17)

13 unit tests cover the algorithm (no-change, mid-file
insert/delete/replacement, whitespace-only change, mismatched
replacement run, 1200-line scale, accept/reject round-trip). Real-world
validation items:

- [ ] **Open two real Swift files in DiffViewer.** Paste the path of a
      file + its previous version (e.g. `git show HEAD~5:Sources/CLI/
      Senkani.swift > /tmp/old.swift` then compare `/tmp/old.swift`
      against the current file). Confirm mid-file insertions/deletions
      align without cascading false-diff rows after the change.
- [ ] **Whitespace-only change.** Load a file, save a trailing-
      whitespace-only variant, compare. Both sides should show the
      differing lines highlighted; unchanged lines above/below should
      stay aligned.
- [ ] **Large file.** Diff two ~2k-line JSON or log files with a
      handful of mid-file edits. Should render in under ~1s and
      preserve scrolling alignment.

### senkani_bundle --remote wiring (shipped 2026-04-17)

22 unit tests (URLProtocol-stubbed) cover parseTree, fetchRemote,
composeRemote markdown+JSON, secret redaction, rate-limit/404
propagation, tree-truncation notice. Real-world validation items:

- [ ] **Bundle a real public repo end-to-end.** Run `senkani bundle
      --remote react-router/react-router --output /tmp/rr.md`
      unauthenticated. Confirm the tree arrives, README is included,
      and the output is under the default budget. Retry with
      `GITHUB_TOKEN` set and observe the `Authorization: Bearer`
      header only hitting `api.github.com` (proxy or `tcpdump` if
      paranoid — the unit tests cover this but live traffic is the
      real gate).
- [ ] **Exercise rate-limit handling on a real anonymous run.** Blast
      `senkani bundle --remote …` five or six times in quick
      succession against a small anonymous quota; confirm the
      user-facing error message names the reset time and exits with
      code 2 rather than crashing or silently returning a partial
      bundle.
- [ ] **Verify tree-truncation banner on a huge repo.** Some repos
      exceed GitHub's 100 KB tree limit — run against one and confirm
      the bundle header includes the "GitHub flagged the tree response
      as truncated" note.
- [ ] **MCP `remote:` argument from a real agent.** From Claude Code
      or Cursor, call `senkani_bundle { remote: "owner/name" }` inside
      a session and confirm the returned snapshot is usable as
      context (outlines list files, README renders, KB + deps are
      empty placeholders with the "remote snapshot" note).

### senkani_bundle JSON format (shipped 2026-04-17)

7 unit tests cover determinism, round-trip, fixture shape, secret
redaction, include-set filtering, and truncation. Real-world
validation items:

- [ ] **Feed `senkani bundle --format json` output into a downstream
      tool.** Pipe the JSON into `jq` to extract the top-N imported
      modules or the outlines for a specific file. Confirm the schema
      is stable enough to script against without string parsing.
- [ ] **Decode against the schema from a second language.** Write a
      short Python snippet (or `jq` walk) that asserts the
      `header.provenance` matches `_Senkani bundle_` and every file in
      `outlines.files[].path` is a real file under the project root.
      Protects against schema drift vs this repo's `BundleDocument`.
- [ ] **Spot-check budget truncation on a big real repo.** Run
      `senkani bundle --format json --budget 2000` on this repo (or
      something larger) and confirm the `truncated` block names a
      section (not null) and the response is still valid JSON.
- [ ] **MCP path.** In a Claude Code session, call
      `senkani_bundle format:"json"` and confirm the returned text is
      parseable JSON. Also confirm the telemetry command string in
      `senkani stats` includes `format=json`.

### senkani_repo (19th MCP tool, shipped 2026-04-17)

29 unit tests cover validation, host allowlist, sanitization, URLProtocol-
stubbed network paths, auth header gating, and cache mechanics. Real-world
validation items:

- [ ] **Rate-limit message on a real API blow.** Make 60+ anonymous calls
      in an hour. Confirm the 61st returns a clear `rateLimited` error
      with remaining count + reset timestamp. Confirm setting
      `GITHUB_TOKEN` resumes normal operation.
- [ ] **Secret redaction on a real repo.** Point `senkani_repo action:readme
      repo:some-repo/with-secrets` at a repo whose README contains a
      known API-key format. Confirm the returned body has `[REDACTED:…]`
      in place of the key.
- [ ] **`action: tree` on a large repo.** Fire against a large real repo
      (kubernetes/kubernetes or similar). Confirm the tree response
      truncation notice appears when output exceeds 100 KB.
- [ ] **Cache hit behavior.** Make the same `senkani_repo action:readme
      repo:owner/name` call twice within 15 min. Confirm
      `senkani stats --security | grep repo_tool.cache.hit` increments.

### Nine-round compound-learning + KB master plan (shipped 2026-04-17, Rounds 1–9)

Rounds 1–8 are shipped in code + unit tests (1204 → 1278, +74 tests
this arc). Round 9 consolidated docs. Six behavioral items below
that unit tests can't cover — exercise when you're back at your machine
with real sessions.

- [ ] **H+2c instruction patches never auto-apply.** Engineer a
      session with ≥3 retries of the same `senkani_search` command,
      repeat across ≥2 sessions. Confirm after the daily sweep that
      `senkani learn status --type filter` shows the instruction patch
      as `Staged`, NOT `Applied`. Confirm a manual
      `senkani learn apply <id>` is the only path that moves it.
- [ ] **H+2c workflow playbook lands at `.senkani/playbooks/learned/`.**
      After a session with ≥3 outline→fetch pairs within 60 s across
      ≥2 sessions, confirm `senkani learn status` shows a playbook.
      Apply it. Confirm the file appears at
      `.senkani/playbooks/learned/outline-then-fetch.md` — NOT under
      `.senkani/skills/`. Hand-edit the description, observe edit
      persists.
- [ ] **H+2d review/audit CLI output is actually useful.** After
      ~1 week of real sessions, run `senkani learn review --days 7`.
      Review the output for decision-making quality: does the grouping
      help you triage? Are staged proposals in the order that matches
      your mental urgency? After ~3 months, run
      `senkani learn audit --idle 60` and note whether the stale-flags
      catch anything worth retiring.
- [ ] **F+1 rebuild on manual edit.** Hand-edit
      `.senkani/knowledge/SomeEntity.md`. Start a new Senkani session.
      Confirm stderr logs `knowledge.rebuild.triggered` and the
      SQLite-indexed `compiledUnderstanding` reflects your edit.
      (Phase F.7 already did this on commit; F+1 adds the staleness
      detection that catches out-of-band edits.)
- [ ] **F+3 validator flags a bad enrichment.** Propose a context
      doc update that deletes the Compiled Understanding section
      (via `senkani_knowledge propose understanding=""`). Confirm the
      validator surfaces `informationLoss`. Commit anyway with
      operator override (TBD — for now, validator output is advisory
      via the CLI). Roll back via `senkani kb rollback SomeEntity`.
- [ ] **F+5 cascade invalidation.** Apply a context doc derived from
      SessionDatabase (title `sessiondatabase-swift`). Roll back the
      SessionDatabase KB entity to yesterday via
      `senkani kb rollback SessionDatabase --to YYYY-MM-DD`. Call
      `KBCompoundBridge.invalidateDerivedContext("SessionDatabase",
      ...)` (wire into the rollback CLI in a follow-up — Round 8
      shipped the bridge, the auto-call-on-rollback is a nice-to-have).
      Confirm the applied context doc drops back to `.recurring`.

### Phase K — Compound Learning H+2b (shipped 2026-04-17)

Round 1 of the nine-round master plan. 27 unit tests cover the polymorphic
store, migration, generator mechanics, lifecycle, session-brief
integration, counter emission. What units can NOT tell you: whether the
*context signals* are useful on a real project. Five items below — all
require your machine with real session activity.

- [ ] **Seed real recurring-file data.** Open 3+ Senkani sessions over
      a day, each reading `Sources/Core/SessionDatabase.swift` (or
      another file you actually work on often). Confirm
      `senkani learn status --type context` shows a `.recurring` doc
      for that path after the third session. Recurrence counter should
      read `×1` on first detection and climb as more sessions flag the
      same file.
- [ ] **Daily sweep promotes it.** Cross the recurrence threshold
      (`CompoundLearning.dailySweepRecurrenceThreshold`, default 3),
      then open a 4th session. Stderr should log
      `[compound_learning] daily sweep promoted N rule(s) → staged`;
      `senkani learn status --type context` should show the doc under
      `Context staged`.
- [ ] **`senkani learn apply <id>` writes to disk.** Apply the staged
      context doc. Confirm
      `.senkani/context/<title>.md` exists with the expected markdown
      body. Hand-edit the body to add a project-specific
      note — preserves through the next session because the file is
      authoritative on `.applied` reads.
- [ ] **Next session's brief includes the doc.** Start a new Senkani
      session. The MCP server's `instructions` field (visible in
      `SENKANI_LOG_JSON=1` stderr or via the Claude Code MCP debug
      surface) should contain a `Session context: … Learned:
      <title> — <first content line>.` section.
- [ ] **Hand-edit → secret leak defense.** Put a fake API key into
      `.senkani/context/<title>.md` (use e.g. `sk-ant-api03-` + 85
      chars). Start a new session. Confirm the brief shows
      `[REDACTED:…]` instead of the raw key — `ContextFileStore.read`
      re-scans at read time, not just on write.

### Phase K — Compound Learning H+2a (shipped 2026-04-17)

22 unit tests cover the mechanics end-to-end with a `MockRationaleLLM`
— prompt capping, output capping, SecretDetector scrubbing on LLM
output, silent fallback on failure, v2→v3 migration, orchestration
hook, threshold config precedence. What the unit tests can NOT tell
you: whether real Gemma 4 output on a real rules file is actually
better than the deterministic rationale. That part is the operator's
job. Five items below — all require your machine with MLX + a Gemma
tier downloaded.

- [ ] **First Gemma enrichment on a real staged rule.** Open a Senkani
      pane (starts an MCP session → triggers `runDailySweep` with the
      MLX-backed adapter). Seed a `.recurring` rule that meets the
      promotion threshold. Confirm the detached Task fires and
      `senkani learn status --enriched` now shows an `✦` line with
      an LLM-generated sentence. Visually inspect for coherence.
- [ ] **Hallucination check on the first 5 enriched rules.** For each
      real enrichment, compare against the deterministic rationale.
      Note any enrichment that introduces facts not supported by the
      rule's command/ops/counts fields. If >1 of 5 hallucinates,
      drop the feature back to deterministic-only via
      `senkani learn config set minConfidence 0.99` (effectively
      disables promotion) pending H+2a+ refinement.
- [ ] **Latency on 8 GB vs 16 GB machines.** Time the enrichment Task
      from `compound_learning.enrichment.queued` bump to
      `compound_learning.enrichment.success`. Record p50/p95. If
      p95 > 5 s, raise the issue — model-load amortization may not
      be working as designed.
- [ ] **No-model fallback.** Temporarily rename
      `~/.cache/huggingface/hub/models--mlx-community--gemma-*` or
      otherwise make the Gemma model unavailable. Run a session.
      Confirm `compound_learning.enrichment.failed` bumps but the
      session itself completes cleanly. `senkani learn status --enriched`
      should quietly fall back to the deterministic rationale (no
      error message).
- [ ] **Config file persistence across restarts.** Run
      `senkani learn config set minConfidence 0.75`. Close the app.
      Reopen. Run `senkani learn config show`. Confirm the value
      persists. Confirm
      `SENKANI_COMPOUND_MIN_CONFIDENCE=0.50 senkani learn config show`
      reports 0.50 (env overrides file).
- [ ] **Distribution log visibility.** Start a session, let
      `runPostSession` fire. Confirm a line like
      `[compound_learning] proposals=N sessions_p50=X p75=X p95=X
      savedpct_p50=X p95=X` lands in the MCP stderr stream (or in
      the JSON log if `SENKANI_LOG_JSON=1`). Over 10+ real sessions
      this produces the histogram that H+2b will use for threshold
      recalibration.

### senkani_bundle (18th MCP tool, shipped 2026-04-17)

Unit tests cover determinism, section order, budget truncation, secret
redaction on embedded content, KB/deps topN caps, README discovery,
empty-project edge case (16 tests). These are the things only a real
project + real LLM can validate.

- [ ] **Bundle an actual Senkani checkout.** Run `senkani bundle --output senkani-bundle.md` in the Senkani repo itself. Open the resulting markdown. Sanity checks:
      - Provenance line lists correct project name, timestamp, budget
      - File order is lex-sorted across the whole Sources/ tree
      - KB section shows the most-mentioned entities from actual sessions
      - README section contains the real README content with no secret leakage
- [ ] **Feed the bundle to a frontier model.** Paste `senkani-bundle.md` into Claude.ai and ask: "Based only on this bundle, what are the main architectural layers?" Compare the answer to what you'd say yourself. This is the Karpathy P3 eval we deferred — human-in-the-loop qualitative signal.
- [ ] **Bundle a large external project.** Run `senkani bundle --budget 40000 --root ~/code/some-big-project`. Confirm the truncation notice fires on the expected section and that the output is still coherent up to that point.
- [ ] **Path traversal defense fires.** Try `senkani bundle --root ~/.aws`. Expect an error, no bundle produced, no file content emitted.
- [ ] **`--output` path defense.** Try `senkani bundle --output /etc/passwd`. Expect either filesystem permission denial OR a clean error, never a partial write.
- [ ] **MCP surface from Claude Code.** Call `senkani_bundle` from a Senkani pane's Claude Code session; confirm the response arrives, respects budget, appears in the Agent Timeline with the correct savings number.

### Phase K — Compound Learning H+1 (shipped 2026-04-17)

Unit tests cover every gate branch, migration, sweep, and counter (1159
total). These are the things only a real session can exercise.

- [ ] **Real post-session loop fires.** Start a real Claude Code session in
      a Senkani pane, run ≥5 uncovered exec commands (e.g.
      `docker compose logs`, `poetry show --tree`), let the session close
      naturally. Then:
      - `senkani learn status` — expect ≥1 rule in the `Recurring` section
        with the new rationale line + confidence %
      - `senkani stats --security | grep compound_learning` — expect at
        least `compound_learning.run.post_session` and one
        `compound_learning.proposal.*` counter
- [ ] **Daily sweep promotes after 3× recurrence.** Repeat the same flow
      across 3 separate sessions with the same uncovered command. On
      session 4 start, stderr should log
      `[compound_learning] daily sweep promoted N rule(s) → staged` and
      `senkani learn status` should show it under `Staged`.
- [ ] **stripMatching generator with real output.** Run a command whose
      output has recurring noise lines (e.g. repeated timestamp
      prefixes). After ≥5 sessions, confirm `senkani learn status`
      surfaces a `stripMatching(<literal>)` proposal — NOT just
      `head(50)`.
- [ ] **Regression gate fires on a no-op proposal.** Engineer a scenario
      where a proposed `head(50)` doesn't actually help (output <50
      lines) and confirm the corresponding rejection counter bumps.
- [ ] **`senkani learn apply` updates FilterPipeline.** Apply a staged
      rule, start a NEW session, run the covered command, confirm
      `senkani_session stats` shows the filter savings the rule
      predicts.
- [ ] **`senkani learn sweep` CLI end-to-end.** Manual trigger outside
      MCPSession startup path — confirm it promotes and prints the
      expected "run `senkani learn apply`" hint.
- [ ] **Rationale surfaces in Agent Timeline pane.** Open the pane while
      a compound-learning event fires; confirm the new rationale string
      is visible (once GUI wiring lands — currently CLI-only).
- [ ] **v1 rules file migrates on a machine that had Phase H installed.**
      Keep a backup of an old `~/.senkani/learned-rules.json` with
      `version: 1`. Launch Senkani, trigger one `save` path, confirm
      file now reads `"version": 2` and every rule has `recurrenceCount`,
      `sources`, `signalType: "failure"`, etc.

### 2026-06-14 — t1d-7 operator CA-install walk (PASS)

- Operator workstation: Chriss-Mac-mini (operator's real Mac).
- Corrected walk (groomed plan was materially STALE — re-derived against
  the shipped `.build/release/senkani`):
  1. `senkani doctor --install-egress-ca` (confirm `INSTALL-EGRESS-CA`) —
     DRY-RUN: generated `~/.senkani/egress-ca.pem` (+ 0600 `egress-ca.key`)
     and PRINTED the install command. No sudo, no Keychain touch (only
     conformer is DryRunTrustInstallExecutor).
  2. Operator ran the printed:
     `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain /Users/clank/.senkani/egress-ca.pem`
     → installed + trusted.
- Trust flip: `verify-cert -p ssl` CSSMERR_TP_NOT_TRUSTED →
  "certificate verification successful" (exit 0).
- SHA-256 fingerprint (matched on-disk cert):
  7A:19:DD:4F:CD:AB:FC:81:E6:2E:E9:81:E7:49:4D:88:4D:46:25:BE:72:73:BF:0B:6B:26:5C:FE:AA:7A:90:39
- CA subject/issuer: O=senkani, CN=senkani Egress MITM Root CA
  (self-signed, CA:TRUE, valid 2026-06-01 → 2036-05-29).
- Body-inspection: `senkani doctor --check-egress` (CA trusted) →
  5/5 host + 8/8 MITM body-inspection + 2/2 CONNECT-path, all DENY, exit 0.
- Browser caveat acknowledged: System trust honored by Safari/curl/system,
  NOT Chrome/Firefox (own stores) — out of scope.
- Teardown:
  `sudo security remove-trusted-cert -d /Users/clank/.senkani/egress-ca.pem`
  then
  `sudo security delete-certificate -c "senkani Egress MITM Root CA" /Library/Keychains/System.keychain`
  → verify-cert back to NOT_TRUSTED; cert "could not be found", 0 copies
  across all keychains; local pem+key preserved. REVERSIBLE confirmed.
- VERDICT: PASS.
- Stale-plan findings: confirm phrase is INSTALL-EGRESS-CA (not INSTALL);
  install/uninstall are dry-run/print-only (no sudo, no Keychain mutation);
  real listener is `senkani egress start` (NOT `serve --egress-proxy`,
  which doesn't exist); CA CN is `senkani Egress MITM Root CA` (NOT
  `senkani-mitm-ca`).
- Teardown-gap defect: `doctor --uninstall-egress-ca` prints only
  `remove-trusted-cert` (removes trust setting, LEAVES the cert object);
  full baseline restore also needs `security delete-certificate`. (This
  item.)

### Prior waves (cross-link to existing queue)

- Wave 1/2/3 hardening soak S1–S12 — see
  `~/.claude/plans/soak-after-wave-3.md` and
  `tools/soak/findings/*.md`.
- `senkani uninstall` — 7 artifact sweep (`spec/cleanup.md` #15).
- `senkani export --redact` round-trip PII check.
- `senkani stats --security` live counter validation.
- Structured-log shape via `SENKANI_LOG_JSON=1`.
- Multi-process migration race (BSD flock cross-process).

---

## When to revisit

Run through this list:

1. When you're back at your physical machine with a real LLM client
   configured.
2. Before any "it works" claim reaches the README comparison
   screenshots (Phase I) or the live-multiplier chart (Phase Q).
3. After any compound-learning behavior change that the unit-test
   fixtures don't simulate (agent variance, human-in-the-loop apply
   decisions, cross-project contamination).

Tick items off with `- [x] — YYYY-MM-DD — notes` lines. If a scenario
surfaces a bug, file it in `spec/cleanup.md` rather than burying the
finding here.
