# Senkani — Manual test queue

Live things that unit tests and CI can't validate. Exercise when you're
back at your machine and can attach Senkani to a real Claude Code (or
Cursor / Codex) session. Tick items off with a date line.

Older queue items are also tracked in `spec/roadmap.md` "Manual test queue
(requires real sessions / user's physical machine)" — this file is the
wave-by-wave operator diary; the roadmap is the long-lived spec.

---

## Cowork-runnable test plans (groomed; ready to execute)

> Pointers to per-item test plans groomed by `/senkani-autonomous`.
> The plan body lives in the per-item file; this section is a
> cadence-friendly index. Operator (or Cowork in Claude Desktop)
> picks one, runs it, follows the `## Operator contract` in the
> linked file, and lets the next `/senkani-autonomous` close-mode
> sweep finalize.

- **uninstall-rewalk-step8-modelmetadatacache — confirm `~/Library/Caches/dev.senkani/` no longer survives `senkani uninstall --yes` after the 9th-category ship** ([groomable plan](../../spec/autonomous/backlog/uninstall-rewalk-step8-modelmetadatacache.md)). Exec mode: **either** (a Step-8 broad-sweep diff; Cowork-runnable, no GUI hands needed beyond the wrapping uninstall walk's pre-existing GUI steps). Time estimate: **~3-5 min standalone, free if folded into the next full uninstall walk**. Pre-condition: a real install with at least one ModelManager model registered (so `dev.senkani/models/models.json` actually exists pre-uninstall). Recommended: bundle into the next overall uninstall walk (likely `release-v0-3-0-uninstall-pass` v3 or v0.4.0's release pass) rather than a dedicated re-run. Filed 2026-05-03 by close of `uninstall-scanner-audit-claude-hook-and-library-caches`; awaits groom-mode → status: manual_ready → operator/Cowork execution → close.

- **release-v0-3-0-uninstall-pass-v2-plan-amendments — `senkani uninstall` real-install validation, v2 (8 steps incl. split 3a/3b, 6 acceptance bullets)** ([archived plan](../../spec/autonomous/completed/2026/2026-05-03-release-v0-3-0-uninstall-pass-v2-plan-amendments-fix-three-defects-from-2026-05-02-walk.md)). Exec mode: **either** (Cowork-runnable for Steps 1, 2, 3b, 4, 5, 7, 8; Steps 3a + 6 SenkaniApp launch need operator hands on first Gatekeeper prompt — bundle is ad-hoc signed). Time: **~12-18 min operator-supervised** (down from 65 min on v1's walk; v2 removes the runner defects that caused retries). Pre-condition: PR #14 landed, a registered SenkaniApp install, AND `tools/soak/runner/SenkaniApp.app` bundle present + fresh (mtime ≥ newest `SenkaniApp/*.swift`). Three v1 defects fixed: A1 sweep race (split into `sweep_targets`/`sweep_broad`), A3 Step-3 pre-seed (foreground `open -a` of bundled `.app`), A5 Step-7 hardcoded target (now ANY workspace project + mtime ≥ TEST_START_EPOCH). Operator decides whether to re-walk on v0.3.0 or hold for v0.4.0 (recommended) BEFORE running. Groomed 2026-05-02 by `senkani-autonomous`. **Status note 2026-05-03: walked + closed strict-literal green on all six A-bullets; per-item file archived to `completed/2026/`. Three optional follow-up findings (runner-bundle launch defect, 4 BROAD scanner-extension candidates, `! pgrep SenkaniApp` pre-condition) are pending operator decision on whether to file as new backlog items. See CHANGELOG `## v0.3.0 — unreleased` → `### May 3` for the full closure record.**

- **release-v0-3-0-uninstall-pass — `senkani uninstall` real-install validation (v1, 8 steps, 6 acceptance bullets)** ([archived plan](../../spec/autonomous/completed/2026/2026-05-02-release-v0-3-0-uninstall-pass-real-install-validation-6-checks-on-live-macos-session.md)). Exec mode: **either** (Cowork-runnable for Steps 1–5, 7, 8; Step 6 SenkaniApp re-launch needs operator hands on first Gatekeeper prompt). Time: ~15 min operator-supervised plan estimate (actual v1 walk: ~65 min — see v2 plan above for fixes). Pre-condition: PR #14 (`ship/v0.3.0-batch-2026-05-01`) landed and a registered SenkaniApp install. Highest-value step is Step 8 orphan sweep — finds new artifact paths the eight-category scanner missed (the `webContentRuleLists` 8th category came from this exact sweep on the 2026-05-02 walk). Groomed 2026-05-02 by `senkani-autonomous`. **Status note 2026-05-03: walked Cowork-driven 2026-05-02, closed on spirit-pass (A6 strict-clean; A1/A3/A5 fail-strict / pass-spirit); finalized 2026-05-03 (A1–A6 boxes flipped per operator-directed Option A) and archived to `completed/2026/`. Strict-fail follow-ups all tracked separately: v2-amendments CLOSED; runner-bundle-smoke CLOSED; uninstall-scanner-audit OPEN; uninstall-test-plan-prerunning-process OPEN. The v2 plan above amends the runner defects surfaced by this walk.**

---

## Wave-by-wave (most recent first)

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
