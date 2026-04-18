# Senkani — Manual test queue

Live things that unit tests and CI can't validate. Exercise when you're
back at your machine and can attach Senkani to a real Claude Code (or
Cursor / Codex) session. Tick items off with a date line.

Older queue items are also tracked in `spec/roadmap.md` "Manual test queue
(requires real sessions / user's physical machine)" — this file is the
wave-by-wave operator diary; the roadmap is the long-lived spec.

---

## Wave-by-wave (most recent first)

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
