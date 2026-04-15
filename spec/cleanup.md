# Cleanup & Technical Debt

> Issues found during April 11 2026 codebase audit. Each entry has: location, problem, fix.
> Ordered by effort × risk. Do these before they compound.

---

## Fix Now (Low Effort, High Risk If Left)

### 1. HookMain.swift + Hook/main.swift — Identical Code (Lesson #16 Violation)

**Location:** `Sources/Core/HookMain.swift` (126 lines) and `Sources/Hook/main.swift` (132 lines)

**Problem:** Two files implement identical Unix socket relay logic to the daemon. Already flagged
as Lesson #16. They will drift. One fix will miss the other.

**Fix:** Resolved April 12. Created zero-dependency library target `HookRelay` containing the canonical implementation. `Sources/Hook/main.swift` is now a 2-line wrapper (`import HookRelay; exit(HookRelay.run())`). `Sources/Core/HookMain.swift` deleted. `SenkaniApp/App/main.swift --hook` branch calls `HookRelay.run()`. Honors both Lesson #12 (zero deps in hook binary) and Lesson #16 (no duplication).

---

### 2. `tokenStatsForPane()` — Dead API That Can't Work

**Location:** `Sources/Core/SessionDatabase.swift`

**Problem:** Method queries `token_events` by `pane_id`. Per-pane attribution is architecturally
impossible when the MCP server is a separate process (Lesson #13). The `pane_id` column exists
but is unreliable. If this method gets called in future UI code, it will return wrong data silently.

**Fix:** Remove the method entirely, OR mark deprecated:
```swift
@available(*, deprecated, message: "Per-pane attribution is architecturally impossible. Use tokenStatsForProject() instead.")
```

**Effort:** 10 minutes. **Risk of not fixing:** Medium — future feature might call it and display wrong numbers.

---

### 3. ClaudeSessionWatcher Hardcodes Model Pricing

**Location:** `SenkaniApp/Services/ClaudeSessionWatcher.swift` — `estimateCost()` method

**Problem:** Hardcodes Opus $15/$75, Sonnet $3/$15, Haiku $0.25/$1.25 per 1M tokens.
`ModelPricing.swift` exists as a separate struct. These rates will stale on the next pricing change.

**Fix:** Replace the hardcoded switch statement with a call to `ModelPricing.cost(for:input:output:)`.

**Effort:** 15 minutes. **Risk of not fixing:** Low now, high when pricing changes (silent wrong numbers).

---

### 4. architecture.md Self-Contradicts on MetricsWatcher/ClaudeSessionWatcher

**Location:** `spec/architecture.md` line 28 vs line 284

**Problem:**
- Line 28: "No JSONL file watchers. No MetricsWatcher. No FSEvents for metrics."
- Line 284: "A `ClaudeSessionWatcher` alongside the existing MetricsWatcher."

`ClaudeSessionWatcher` IS an FSEvents watcher (on Claude's session JSONL files). The distinction
is: no FSEvents on *Senkani's own metrics* JSONL — that approach was abandoned. But watching
*Claude's session* JSONL via FSEvents is correct and intentional.

**Fix:** Replace line 284 reference to clarify:
- Remove "alongside the existing MetricsWatcher" (MetricsWatcher is deprecated)
- Add note: "ClaudeSessionWatcher uses FSEvents on `~/.claude/projects/` — this is correct and
  intentional (Tier 1 exact tracking). The deprecated MetricsWatcher watched Senkani's own JSONL
  metrics files — that approach was abandoned."

**Effort:** 5 minutes.

---

## Fix Soon (Medium Effort, Quality Gap)

### 5. MetricsWatcher Dead Code

**Location:** Likely `SenkaniApp/Services/MetricsWatcher.swift` (or similar)

**Problem:** `spec/roadmap.md` has listed "MetricsWatcher: ❌ Deprecated — dead code pending cleanup"
since the April 8 status. Dead code creates confusion about intent and inflates binary size.

**Fix:** Resolved April 12. File was already a 6-line comment-only stub. Deleted. Grep confirmed no code imports referenced it — only comments in adjacent files mentioned the name.

---

### 6. DiffViewer Uses Naive Line Diff

**Location:** The DiffViewer pane view (likely `SenkaniApp/Views/DiffViewerView.swift`)

**Problem:** Simple line-by-line comparison. For any file with insertions/deletions in the middle,
the diff produces wrong context — everything after the insertion shows as changed. Makes the diff
viewer unreliable on real code changes.

**Fix:** Implement LCS (longest common subsequence) diff. Swift standard library doesn't have one
but the algorithm is ~50 lines. Or vendor a lightweight diff library.

**Effort:** 2-3 hours.

---

### 7. senkani_vision Memory Pressure TODO (Unresolved)

**Location:** `Sources/MCP/Tools/VisionTool.swift` — marked TODO

**Problem:** MLX doesn't expose a buffer unload API. Running vision inference + embedding
inference simultaneously in the daemon could exhaust Apple Silicon RAM on 8GB machines.
Currently no serialization or load/unload lifecycle.

**Fix:** Add a global `MLXInferenceLock` (serializes vision + embed calls). Then add memory
pressure notification handler (`ProcessInfo.processInfo.performMemoryWarning`) to log and
downgrade gracefully.

**Effort:** 3-4 hours.

---

### 8. `senkani uninstall` CLI Command — Listed But Unimplemented

**Location:** `Sources/CLI/Senkani.swift`

**Problem:** `senkani uninstall` (or similar) appears in the CLI command list but has no
implementation. Users who want to fully remove Senkani have no clean path.

**Fix:** Implement `UninstallCommand.swift`:
- Remove hooks from `~/.claude/settings.json`
- Remove `mcpServers.senkani` entries from all agent configs
- Remove `~/.senkani/` directory (with confirmation prompt)
- Reverse everything `senkani init` does

**Effort:** 2 hours (uses existing `HookRegistration.unregisterForProject()` + `AutoRegistration` internals).

---

## Review Deeper (Architectural Concerns)

### 9. Budget Enforcement at Two Layers — Needs Tests at Both

**Locations:** `Sources/MCP/ToolRouter.swift` (budget gate before MCP tools) and
`Sources/Core/HookRouter.swift` (budget check in PreToolUse handler)

**Problem:** Budget enforcement happens at both layers, which is correct. But the spec/testing.md
quality baselines only describe hook-layer enforcement tests. If the ToolRouter gate is removed or
broken, no test catches it. The two layers should have independent test coverage.

**Review:** Verify acceptance tests cover both: (a) MCP tool call blocked by ToolRouter budget
gate, (b) non-MCP tool call blocked by hook budget gate. Add missing tests.

---

### 10. senkani_pane Uses File-Based IPC

**Location:** `Sources/MCP/Tools/PaneTool.swift` (or similar)

**Problem:** senkani_pane uses a JSONL queue file with 5-second polling. Every other Senkani
IPC uses the Unix domain socket (`~/.senkani/hook.sock` / `~/.senkani/mcp.sock`). The file-based
path is slower (5s latency) and adds another I/O dependency.

**Review:** Currently acceptable — pane control isn't latency-sensitive. But if broadcast mode
or workstream isolation is built on top of senkani_pane, the 5-second poll will be a hard blocker.
Plan to migrate to the socket path before building those features.

---

### 11. MetricsStore.shared Intermediary — Potential Staleness

**Location:** `SenkaniApp/` — the `MetricsStore` class used by StatusBarView and SidebarView

**Problem:** The UI queries `MetricsStore.shared` rather than `SessionDatabase` directly (as
spec/architecture.md describes). If MetricsStore caches values between DB writes, there could be
a staleness window where the UI shows stale numbers even though the DB has fresh data.

**Review:** Verify MetricsStore's cache TTL vs the 1-second timer in StatusBarView. If MetricsStore
caches longer than 1 second, the UI will lag behind. Ensure MetricsStore invalidates on every DB
write or is effectively passthrough.

---

### 12. `--socket-server` Headless Mode — No Restart/Health-Check Mechanism

**Location:** `SenkaniApp/App/main.swift` (the `--socket-server` branch)

**Problem:** The daemon runs via `dispatchMain()`. If the socket server crashes, there is no
watchdog or restart mechanism. Hook events will silently passthrough (correct fail-safe behavior)
but the user won't know the daemon is down until metrics stop updating.

**Review:** Consider adding a health-check endpoint to the socket server (e.g., `senkani doctor`
pings it). Or a launchd keepalive plist for the socket server mode. At minimum, `senkani doctor`
should verify the daemon is responsive, not just that the socket file exists.

---

### 13. Display Settings — Stub

**Location:** `SenkaniApp/Views/PaneSettingsPanel.swift` — Display section

**Problem:** The Display section of the settings panel is a single subtitle line:
"Font size, color overrides, and terminal appearance." Nothing is implemented.

**Review:** Decide scope before building. Minimum viable: font size slider (persisted to pane config)
and monospace font family picker. Full scope would include per-pane color overrides, which requires
threading new config through SwiftTerm.

---

## Build Next (New Ideas, Prerequisites Now Landing)

### 14. Symbol Staleness Notifications (Prerequisite: FSEvents re-indexing ✅ built April 11)

FSEvents auto-trigger + TreeCache + IncrementalParser are all shipped. The notification layer is now unblocked. See [tree_sitter.md](tree_sitter.md).

- Add `queriedSymbols: Set<String>` to `MCPSession`
- Populate on `senkani_search`, `senkani_fetch`, `senkani_outline` calls
- On FileWatcher-triggered re-index, diff changed symbols against `queriedSymbols`
- Prepend one-line notice to next tool response if any match; clear after delivery

**Effort:** ~3 hours. **Value:** Catches silent "working with stale symbol knowledge" failures — agent makes a plan based on symbol X, user edits X mid-session, agent proceeds with stale knowledge. Currently undetectable.

### 15. Manual Test: `senkani uninstall` (Built April 13, Untested)

**Location:** `Sources/CLI/UninstallCommand.swift`

**Status:** Code compiled and registered. NOT manually tested yet. The command removes 7 artifact types (global MCP, project hooks, hook binary, ~/.senkani/, session DB, launchd plists, per-project .senkani/ dirs). Has `--yes` (skip confirmation) and `--keep-data` (preserve session DB) flags.

**Test checklist:**
- [ ] `senkani uninstall` — shows artifact list, asks confirmation, cancel with N → nothing removed
- [ ] `senkani uninstall --keep-data` — list omits session database
- [ ] `senkani uninstall --yes` — full removal, verify all artifacts gone
- [ ] After uninstall: `claude` in plain terminal shows no Senkani tools
- [ ] After uninstall: re-launch Senkani app → re-registers everything (reversible)
- [ ] `senkani uninstall --yes` twice → second run says "Nothing to uninstall" (idempotent)

**Effort:** 10 minutes manual testing. **Risk of not testing:** HIGH — a broken uninstall is worse than no uninstall (partial removal leaves the system in an undefined state).

### 16. Adaptive Truncation Based on Budget Remaining

See [optimization_layers.md](optimization_layers.md).

`BudgetConfig` is already in `ToolRouter.route()`. Add budget-aware threshold scaling to
ExecTool's truncation logic. No new infrastructure.

**Effort:** ~1 hour. **Value:** Passive optimization that activates exactly when it's needed most.

---

## Spec Sync Needed

These spec files describe something that no longer matches reality and need updating when there's time:

| File | Issue |
|------|-------|
| `spec/architecture.md` | Line 284: remove reference to "existing MetricsWatcher" (deprecated). Also covered by item #4 above. |
| `spec/tree_sitter.md` | ✅ Updated April 11 — language matrix shows 20 built, incremental + FSEvents documented. |
| `spec/roadmap.md` | ✅ Updated April 11 — Phase D code-intelligence half marked complete, Phase E marked done, test count bumped to 412. Strategic considerations block added. |
| `spec/testing.md` | ✅ Updated April 11 — Token Savings Test Suite marked built, live-session caveat added, deferred tasks enumerated. |
| `spec/mcp_tools.md` | ✅ Updated April 11 — output sandboxing pattern marked built. |

---

## Outside Review Notes (April 11)

A Claude Code session running through Senkani's own MCP server was asked to critique the project from the spec alone. Layer 2 hooks correctly intercepted the Read calls and redirected them through `senkani_read` — good validation that hook enforcement works on a real agent session. The review surfaced four strategic points, now captured in [roadmap.md](roadmap.md) under "Strategic Considerations":

1. **Phase F vs Phase G ordering** — AAAK is highest-ROI but riskiest; shipping polish first would validate the current 5x before stacking speculative 8-10x on top.
2. **The 80.37x headline is fragile** — fixture bench only. Needs a live-session companion number before any marketing use.
3. **Layer 3 is the moat but unbuilt** — until Phase I ships, a skeptical observer is right to call Senkani "a good MCP wrapper" rather than something categorically different. Consider a minimal Phase I wedge (just re-read suppression) before Phase H.
4. **Cleanup items 1, 5, 10 should land before new features** — HookMain duplication (5 min), MetricsWatcher dead code (30 min), senkani_pane socket migration (before workstream isolation).

These are open questions, not decisions. They exist so future choices are deliberate, not path-dependent.
