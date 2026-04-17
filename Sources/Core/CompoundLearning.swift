import Foundation
import Filter

// MARK: - CompoundLearning
//
// Phase H (April 15) wedge: post-session SQL waste analysis → head(50)
// proposal → builtin-coverage gate → stage to learned-rules.json.
//
// Phase H+1 (April 17) additions, per Luminary audit 2026-04-17:
//
//   • Proposals land in `.recurring` first, not `.staged`. A daily
//     cadence sweep promotes `.recurring` rules with enough evidence.
//   • Confidence uses Laplace smoothing — tiny samples shrink toward
//     the prior instead of producing spurious near-1.0 scores.
//   • Gate returns an enumerated `GateResult` (not `Bool`) so every
//     rejection is counted and diagnosable.
//   • Gate now checks against existing learned rules (Schneier), not
//     just builtins.
//   • `stripMatching` proposals mine top recurring lines from
//     `commands.output_preview` in addition to the blunt `head(50)`
//     proposal. Substring patterns only — no regex, no ReDoS.
//   • Each proposal carries a deterministic `rationale` string
//     (<=140 chars) surfaced in `senkani learn status` — Jobs.
//   • Every gate branch bumps an `event_counters` row — Majors.
//   • `runDailySweep(...)` is called from `MCPSession.resolve()` so
//     the aggregation loop is lazy — no launchd tick, no timer.
//
// Everything H+2 wants — LLM-proposed regex, human-gated sprint review,
// signal types beyond `.failure` — builds on this scaffold without
// another schema migration. The LearnedFilterRule v2 already carries
// the fields.

public enum CompoundLearning {

    // MARK: - Thresholds (H+2a: resolved at call time via CompoundLearningConfig)
    //
    // Phase K shipped these as `static let` constants. Phase H+2a routes
    // every read through `CompoundLearningConfig.resolve()` so an operator
    // can override via `~/.senkani/compound-learning.json` or env vars
    // without a rebuild. Values remain frozen at the Phase K defaults
    // until real-session telemetry (the Manual test queue) recalibrates.
    //
    // Keep the old static names as computed properties — existing call
    // sites inside Core (this file) and tests that read them still work.

    /// Minimum posterior confidence for any proposal to reach `.recurring`.
    public static var minConfidence: Double {
        CompoundLearningConfig.resolve().minConfidence
    }

    /// Minimum `recurrenceCount` a `.recurring` rule needs before the
    /// daily sweep will promote it to `.staged` (visible to the operator).
    public static var dailySweepRecurrenceThreshold: Int {
        CompoundLearningConfig.resolve().dailySweepRecurrenceThreshold
    }

    /// Minimum confidence required on top of the recurrence threshold.
    public static var dailySweepConfidenceThreshold: Double {
        CompoundLearningConfig.resolve().dailySweepConfidenceThreshold
    }

    /// How many output-preview lines to consider as stripMatching
    /// candidates per command. Bounds proposal volume and keeps the
    /// SQL query cheap.
    public static let maxStripMatchingProposalsPerCommand: Int = 2

    /// A recurring line must appear in ≥ this many sample outputs to
    /// earn a stripMatching proposal — prevents one-off noise.
    public static let stripMatchingMinLineFrequency: Int = 3

    /// Longest substring we'll ever propose for stripMatching. Guards
    /// against accidentally stripping a real error line that happens
    /// to share a long prefix with a noise line.
    public static let stripMatchingMaxSubstringLength: Int = 80

    // MARK: - Post-Session Entry Point

    /// Run post-session waste analysis and record any proposals in
    /// `.recurring` status. Non-blocking — always called from
    /// `Task.detached(priority: .background)` by `MCPSession.shutdown()`.
    ///
    /// Behavior change from H: proposals land as `.recurring`, not
    /// `.staged`. Call `runDailySweep` at session start to promote
    /// recurring-with-evidence rules to `.staged`.
    ///
    /// H+2a: emits a compact distribution line to stderr so operators
    /// can start accumulating data for Manual test queue's threshold
    /// recalibration work. Also surfaces the same counts through
    /// `event_counters` so `senkani stats --security` aggregates them.
    public static func runPostSession(
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase = .shared
    ) async {
        db.recordEvent(type: "compound_learning.run.post_session", projectRoot: projectRoot)

        // H+2b context-signal detection — recurring file mentions
        // across sessions become priming-doc proposals. Runs BEFORE
        // the waste-report short-circuit so context signals fire even
        // in sessions with no unfiltered exec commands.
        runContextSignalDetection(
            sessionId: sessionId,
            projectRoot: projectRoot,
            db: db
        )

        // H+2c — instruction retry patterns → instruction patches.
        runInstructionSignalDetection(
            sessionId: sessionId,
            projectRoot: projectRoot,
            db: db
        )

        // H+2c — repeating tool-call pairs → workflow playbooks.
        runWorkflowSignalDetection(
            sessionId: sessionId,
            projectRoot: projectRoot,
            db: db
        )

        let report = WasteAnalyzer.analyze(
            projectRoot: projectRoot,
            sessionId: sessionId,
            db: db
        )
        guard !report.isEmpty else { return }

        // H+2a distribution logging — cheap summary for threshold
        // calibration. Report session counts and savings percentiles
        // of the proposals we saw this run. Stderr-only (structured
        // logs pick it up when `SENKANI_LOG_JSON=1`).
        logDistribution(report: report)

        for cmd in report.unfilteredCommands {
            // ----- head(50) proposal — always considered -----
            let headRule = makeHeadProposal(from: cmd, sessionId: sessionId)
            let headOutcome = gateAndRecord(
                proposed: headRule, projectRoot: projectRoot, db: db
            )
            if headOutcome.isAccepted {
                try? LearnedRulesStore.observe(headRule)
            }

            // ----- stripMatching proposals — optional, data-driven -----
            let stripRules = makeStripMatchingProposals(
                from: cmd, sessionId: sessionId, projectRoot: projectRoot, db: db
            )
            for strip in stripRules {
                let outcome = gateAndRecord(
                    proposed: strip, projectRoot: projectRoot, db: db
                )
                if outcome.isAccepted {
                    try? LearnedRulesStore.observe(strip)
                }
            }
        }
    }

    // MARK: - Daily Cadence Sweep

    /// Lazy daily-cadence sweep: walks `.recurring` rules and promotes
    /// those with `recurrenceCount ≥ dailySweepRecurrenceThreshold`
    /// AND `confidence ≥ dailySweepConfidenceThreshold` to `.staged`
    /// so the operator sees them on the next `senkani learn status`.
    ///
    /// Called from `MCPSession.resolve()` at session start — zero timers.
    /// `db` is passed so the sweep bumps event counters even when run
    /// from a process that doesn't share the app's SessionDatabase
    /// singleton (e.g., CLI commands).
    ///
    /// H+2a: when `enricher` is supplied, promotions trigger a detached
    /// Task that rewrites the rule's deterministic rationale into a
    /// natural-language form and stores it under `enrichedRationale`.
    /// Never blocks the sweep. Never mutates the FilterRule itself.
    ///
    /// - Returns: the number of rules promoted this run.
    @discardableResult
    public static func runDailySweep(
        db: SessionDatabase = .shared,
        projectRoot: String? = nil,
        enricher: GemmaRationaleRewriter? = nil
    ) -> Int {
        db.recordEvent(type: "compound_learning.daily_sweep.run", projectRoot: projectRoot)

        // H+2b: sweep context docs too — independent of filter rules.
        _ = runContextSweep(db: db, projectRoot: projectRoot)
        // H+2c: instruction + workflow signals follow the same
        // recurring-gated promotion pattern.
        _ = runInstructionSweep(db: db, projectRoot: projectRoot)
        _ = runWorkflowSweep(db: db, projectRoot: projectRoot)

        let recurring = LearnedRulesStore.loadRecurring()
        guard !recurring.isEmpty else { return 0 }

        var promoted = 0
        for rule in recurring {
            guard rule.recurrenceCount >= dailySweepRecurrenceThreshold,
                  rule.confidence >= dailySweepConfidenceThreshold
            else { continue }
            try? LearnedRulesStore.promoteToStaged(id: rule.id)
            db.recordEvent(
                type: "compound_learning.daily_sweep.promoted",
                projectRoot: projectRoot
            )
            promoted += 1

            if let enricher {
                let ruleCopy = rule
                let capturedRoot = projectRoot
                db.recordEvent(
                    type: "compound_learning.enrichment.queued",
                    projectRoot: capturedRoot
                )
                Task.detached(priority: .background) {
                    let enriched = await enricher.enrich(ruleCopy)
                    if let text = enriched {
                        try? LearnedRulesStore.setEnrichedRationale(
                            id: ruleCopy.id, text: text)
                        db.recordEvent(
                            type: "compound_learning.enrichment.success",
                            projectRoot: capturedRoot)
                    } else {
                        db.recordEvent(
                            type: "compound_learning.enrichment.failed",
                            projectRoot: capturedRoot)
                    }
                }
            }
        }
        return promoted
    }

    /// H+2a — blocking enrich path used by `senkani learn enrich`. Walks
    /// all staged rules whose `enrichedRationale` is nil and attempts
    /// to fill it. Returns the number of successful rewrites.
    @discardableResult
    public static func enrichStagedRules(
        enricher: GemmaRationaleRewriter,
        db: SessionDatabase = .shared,
        projectRoot: String? = nil,
        ids: Set<String>? = nil
    ) async -> Int {
        let file = LearnedRulesStore.load() ?? .empty
        let candidates = file.rules.filter { rule in
            guard rule.status == .staged else { return false }
            guard rule.enrichedRationale == nil else { return false }
            if let ids = ids, !ids.isEmpty { return ids.contains(rule.id) }
            return true
        }
        guard !candidates.isEmpty else { return 0 }

        var succeeded = 0
        for rule in candidates {
            db.recordEvent(type: "compound_learning.enrichment.queued",
                           projectRoot: projectRoot)
            let enriched = await enricher.enrich(rule)
            if let text = enriched {
                try? LearnedRulesStore.setEnrichedRationale(id: rule.id, text: text)
                db.recordEvent(type: "compound_learning.enrichment.success",
                               projectRoot: projectRoot)
                succeeded += 1
            } else {
                db.recordEvent(type: "compound_learning.enrichment.failed",
                               projectRoot: projectRoot)
            }
        }
        return succeeded
    }

    // MARK: - Gate

    /// Evaluate a proposed rule against the full gate stack:
    ///   1. Already covered by builtin rule? → reject
    ///   2. Already in non-terminal learned state? → reject
    ///   3. Regression / below-threshold vs. output samples? → reject
    ///   4. Confidence below `minConfidence`? → reject (threshold)
    ///   5. Otherwise → accept
    ///
    /// Step 3 requires a source of samples; callers that don't pass a
    /// DB can't run it (use `runGate(...)` for unit tests).
    public static func evaluateProposal(
        _ rule: LearnedFilterRule,
        projectRoot: String?,
        db: SessionDatabase
    ) -> GateResult {
        // 1. Builtin coverage
        if let match = CommandMatcher.parse(rule.command) {
            if BuiltinRules.rules.contains(where: { $0.matches(match) }) {
                return .rejectedBuiltinCovered
            }
        }

        // 2. Already learned (staged / applied / recurring — dedup by
        //    command+subcommand+ops so slightly-different rules for
        //    the same command can still coexist if that ever matters)
        let existing = (LearnedRulesStore.load() ?? .empty).rules
        let duplicate = existing.contains { other in
            other.command == rule.command &&
            other.subcommand == rule.subcommand &&
            other.ops == rule.ops &&
            (other.status == .staged || other.status == .applied)
        }
        if duplicate { return .rejectedAlreadyLearned }

        // 3. Regression gate — samples from `commands.output_preview`.
        //    Use the base command as the prefix so variants with
        //    different flags (e.g. `docker compose logs --tail 20`) all
        //    contribute. Empty-sample path is a no-op `.accepted`.
        let samplePrefix = [rule.command, rule.subcommand].compactMap { $0 }.joined(separator: " ")
        let previews = db.outputPreviewsForCommand(
            projectRoot: projectRoot,
            commandPrefix: samplePrefix,
            limit: 20
        )
        let samples = previews.map {
            RegressionGate.Sample(command: samplePrefix, output: $0)
        }
        let regressionOutcome = RegressionGate.check(
            proposed: rule.asFilterRule,
            samples: samples
        )
        if !regressionOutcome.isAccepted { return regressionOutcome }

        // 4. Confidence threshold
        if rule.confidence < minConfidence {
            return .rejectedBelowThreshold(reason: String(
                format: "confidence %.2f < min %.2f",
                rule.confidence, minConfidence))
        }

        return .accepted
    }

    /// Back-compat Phase H shim. Returns `true` iff the proposal clears
    /// the builtin-coverage gate (the only H-era check). Retained for
    /// tests and `senkani learn --dry-run` callers that only have a rule
    /// in hand, no DB. New code should call `evaluateProposal(...)`.
    public static func runGate(proposed: LearnedFilterRule) -> Bool {
        guard let match = CommandMatcher.parse(proposed.command) else { return false }
        return !BuiltinRules.rules.contains { $0.matches(match) }
    }

    // MARK: - Proposal Construction

    /// Build the deterministic `head(50)` proposal for an unfiltered command.
    /// Rationale is generated from the waste report — no ML, no surprise.
    public static func makeHeadProposal(
        from cmd: UnfilteredCommand,
        sessionId: String,
        now: Date = Date()
    ) -> LearnedFilterRule {
        let confidence = ConfidenceEstimator.laplace(
            avgSavedPct: cmd.avgSavedPct,
            sessionCount: cmd.sessionCount
        )
        let subPart = cmd.subcommand.map { " \($0)" } ?? ""
        let rationale = String(
            format: "%@%@: seen in %d sessions, avg %.0f%% saved — head(50) caps runaway output.",
            cmd.baseCommand, subPart, cmd.sessionCount, cmd.avgSavedPct
        )
        return LearnedFilterRule(
            id: UUID().uuidString,
            command: cmd.baseCommand,
            subcommand: cmd.subcommand,
            ops: ["head(50)"],
            source: sessionId,
            confidence: confidence,
            status: .recurring,
            sessionCount: cmd.sessionCount,
            createdAt: now,
            rationale: String(rationale.prefix(140)),
            signalType: .failure,
            recurrenceCount: 1,
            lastSeenAt: now,
            sources: [sessionId]
        )
    }

    /// Build `stripMatching(<line>)` proposals mined from the command's
    /// actual output previews. Substring literals only — no regex. Capped
    /// at `maxStripMatchingProposalsPerCommand` to bound proposal volume.
    public static func makeStripMatchingProposals(
        from cmd: UnfilteredCommand,
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase,
        now: Date = Date()
    ) -> [LearnedFilterRule] {
        let prefix = [cmd.baseCommand, cmd.subcommand].compactMap { $0 }.joined(separator: " ")
        let previews = db.outputPreviewsForCommand(
            projectRoot: projectRoot,
            commandPrefix: prefix,
            limit: 50
        )
        guard previews.count >= stripMatchingMinLineFrequency else { return [] }

        // Line frequency across sample outputs. We match "line after
        // leading whitespace, truncated to stripMatchingMaxSubstringLength"
        // so multiple "INFO 2026-04-17T..." lines with different
        // timestamps don't look unique — the shared substring is what
        // lets stripMatching fire across all of them.
        var frequency: [String: Int] = [:]
        for preview in previews {
            var seenThisPreview: Set<String> = []
            for line in preview.split(separator: "\n") {
                let trimmed = line.drop(while: { $0.isWhitespace })
                guard trimmed.count >= 4 else { continue }
                let clipped = String(trimmed.prefix(stripMatchingMaxSubstringLength))
                // Only count once per preview so a line repeated 50x in
                // one sample doesn't crowd out cross-sample recurrence.
                if seenThisPreview.insert(clipped).inserted {
                    frequency[clipped, default: 0] += 1
                }
            }
        }

        // Keep only lines that recur across enough samples.
        let recurring = frequency
            .filter { $0.value >= stripMatchingMinLineFrequency }
            .sorted { $0.value > $1.value }
            .prefix(maxStripMatchingProposalsPerCommand)

        let confidence = ConfidenceEstimator.laplace(
            avgSavedPct: cmd.avgSavedPct,
            sessionCount: cmd.sessionCount
        )

        return recurring.map { (pattern, freq) -> LearnedFilterRule in
            let subPart = cmd.subcommand.map { " \($0)" } ?? ""
            // Pattern might contain `)` which breaks our op serializer.
            // Guard against it by truncating at the first such byte —
            // LineOperations uses `contains`, so a shorter pattern still
            // matches. Belt + suspenders vs. parseStringArg in the
            // rule deserializer.
            let safePattern = String(pattern.prefix { $0 != ")" })
            let rationale = String(
                format: "%@%@: %d/%d samples repeat this line — strip to save tokens.",
                cmd.baseCommand, subPart, freq, previews.count
            )
            return LearnedFilterRule(
                id: UUID().uuidString,
                command: cmd.baseCommand,
                subcommand: cmd.subcommand,
                ops: ["stripMatching(\(safePattern))"],
                source: sessionId,
                confidence: confidence,
                status: .recurring,
                sessionCount: cmd.sessionCount,
                createdAt: now,
                rationale: String(rationale.prefix(140)),
                signalType: .failure,
                recurrenceCount: 1,
                lastSeenAt: now,
                sources: [sessionId]
            )
        }
    }

    // MARK: - Private helpers

    /// Evaluate + record the event-counter bump for a single proposal.
    /// Returns the gate outcome so callers can decide whether to observe.
    private static func gateAndRecord(
        proposed: LearnedFilterRule,
        projectRoot: String,
        db: SessionDatabase
    ) -> GateResult {
        let outcome = evaluateProposal(proposed, projectRoot: projectRoot, db: db)
        db.recordEvent(type: outcome.eventCounterKey, projectRoot: projectRoot)
        return outcome
    }

    // MARK: - Context signal detection (H+2b)

    /// Generate context-doc proposals from recurring file mentions and
    /// record each via `LearnedRulesStore.observeContextDoc`. Counters
    /// bump per proposed artifact; the daily sweep promotes these to
    /// `.staged` using the same `recurrenceCount`-gated logic as filter
    /// rules.
    static func runContextSignalDetection(
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase
    ) {
        let proposals = ContextSignalGenerator.analyze(
            projectRoot: projectRoot,
            sessionId: sessionId,
            db: db
        )
        for proposal in proposals {
            // Confidence gate — Laplace prior keeps low-N proposals below
            // threshold; same floor as filter rules.
            guard proposal.confidence >= minConfidence else {
                db.recordEvent(
                    type: "compound_learning.context.rejected",
                    projectRoot: projectRoot
                )
                continue
            }
            try? LearnedRulesStore.observeContextDoc(proposal)
            db.recordEvent(
                type: "compound_learning.context.proposed",
                projectRoot: projectRoot
            )
        }
    }

    /// H+2b — daily-sweep equivalent for context docs. Promotes any
    /// `.recurring` context doc whose recurrenceCount + confidence
    /// clear the thresholds. Called from `runDailySweep` alongside the
    /// filter-rule promotion loop.
    @discardableResult
    public static func runContextSweep(
        db: SessionDatabase = .shared,
        projectRoot: String? = nil
    ) -> Int {
        let recurring = LearnedRulesStore.contextDocs(inStatus: .recurring)
        var promoted = 0
        for doc in recurring {
            guard doc.recurrenceCount >= dailySweepRecurrenceThreshold,
                  doc.confidence >= dailySweepConfidenceThreshold
            else { continue }
            try? LearnedRulesStore.promoteContextDocToStaged(id: doc.id)
            db.recordEvent(
                type: "compound_learning.context.promoted",
                projectRoot: projectRoot
            )
            promoted += 1
        }
        return promoted
    }

    /// Apply a staged context doc: flip status to `.applied` AND write
    /// the markdown body to disk under `.senkani/context/<title>.md`.
    /// The on-disk file is what operators hand-edit; the agent sees it
    /// through `SessionBriefGenerator`.
    public static func applyContextDoc(
        id: String,
        projectRoot: String,
        db: SessionDatabase = .shared
    ) throws {
        try LearnedRulesStore.applyContextDoc(id: id)
        guard let doc = (LearnedRulesStore.load() ?? .empty)
            .contextDocs.first(where: { $0.id == id })
        else { return }
        try ContextFileStore.write(doc: doc, projectRoot: projectRoot)
        db.recordEvent(
            type: "compound_learning.context.applied",
            projectRoot: projectRoot
        )
    }

    // MARK: - Instruction signal detection (H+2c)

    static func runInstructionSignalDetection(
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase
    ) {
        let proposals = InstructionSignalGenerator.analyze(
            projectRoot: projectRoot,
            sessionId: sessionId,
            db: db
        )
        for proposal in proposals {
            guard proposal.confidence >= minConfidence else {
                db.recordEvent(
                    type: "compound_learning.instruction.rejected",
                    projectRoot: projectRoot)
                continue
            }
            try? LearnedRulesStore.observeInstructionPatch(proposal)
            db.recordEvent(
                type: "compound_learning.instruction.proposed",
                projectRoot: projectRoot)
        }
    }

    @discardableResult
    public static func runInstructionSweep(
        db: SessionDatabase = .shared,
        projectRoot: String? = nil
    ) -> Int {
        let recurring = LearnedRulesStore.instructionPatches(inStatus: .recurring)
        var promoted = 0
        for patch in recurring {
            guard patch.recurrenceCount >= dailySweepRecurrenceThreshold,
                  patch.confidence >= dailySweepConfidenceThreshold
            else { continue }
            try? LearnedRulesStore.promoteInstructionPatchToStaged(id: patch.id)
            db.recordEvent(
                type: "compound_learning.instruction.promoted",
                projectRoot: projectRoot)
            promoted += 1
        }
        return promoted
    }

    /// Apply an instruction patch. Schneier-constraint enforced: this
    /// is the ONLY auto-capable apply path, and it exists but requires
    /// the operator to call it directly OR set
    /// `SENKANI_INSTRUCTION_AUTO_APPLY=on`. The daily sweep never calls
    /// this automatically — it only stages.
    public static func applyInstructionPatch(
        id: String,
        db: SessionDatabase = .shared,
        projectRoot: String? = nil
    ) throws {
        try LearnedRulesStore.applyInstructionPatch(id: id)
        db.recordEvent(
            type: "compound_learning.instruction.applied",
            projectRoot: projectRoot)
    }

    // MARK: - Workflow signal detection (H+2c)

    static func runWorkflowSignalDetection(
        sessionId: String,
        projectRoot: String,
        db: SessionDatabase
    ) {
        let proposals = WorkflowSignalGenerator.analyze(
            projectRoot: projectRoot,
            sessionId: sessionId,
            db: db
        )
        for proposal in proposals {
            guard proposal.confidence >= minConfidence else {
                db.recordEvent(
                    type: "compound_learning.workflow.rejected",
                    projectRoot: projectRoot)
                continue
            }
            try? LearnedRulesStore.observeWorkflowPlaybook(proposal)
            db.recordEvent(
                type: "compound_learning.workflow.proposed",
                projectRoot: projectRoot)
        }
    }

    @discardableResult
    public static func runWorkflowSweep(
        db: SessionDatabase = .shared,
        projectRoot: String? = nil
    ) -> Int {
        let recurring = LearnedRulesStore.workflowPlaybooks(inStatus: .recurring)
        var promoted = 0
        for playbook in recurring {
            guard playbook.recurrenceCount >= dailySweepRecurrenceThreshold,
                  playbook.confidence >= dailySweepConfidenceThreshold
            else { continue }
            try? LearnedRulesStore.promoteWorkflowPlaybookToStaged(id: playbook.id)
            db.recordEvent(
                type: "compound_learning.workflow.promoted",
                projectRoot: projectRoot)
            promoted += 1
        }
        return promoted
    }

    /// Apply a staged workflow playbook — writes markdown to
    /// `.senkani/playbooks/learned/<title>.md` and flips status.
    public static func applyWorkflowPlaybook(
        id: String,
        projectRoot: String,
        db: SessionDatabase = .shared
    ) throws {
        try LearnedRulesStore.applyWorkflowPlaybook(id: id)
        guard let w = (LearnedRulesStore.load() ?? .empty)
            .workflowPlaybooks.first(where: { $0.id == id })
        else { return }
        try PlaybookFileStore.write(playbook: w, projectRoot: projectRoot)
        db.recordEvent(
            type: "compound_learning.workflow.applied",
            projectRoot: projectRoot)
    }

    // MARK: - Distribution logging (H+2a — Gelman infrastructure)

    /// Emit a compact line capturing session-count and savings-percentile
    /// distribution of the proposals in `report`. Threshold recalibration
    /// (Manual test queue, H+2b) reads structured logs for this line.
    private static func logDistribution(report: WasteReport) {
        let sessions = report.unfilteredCommands.map(\.sessionCount).sorted()
        let savingsPct = report.unfilteredCommands.map(\.avgSavedPct).sorted()
        let n = report.unfilteredCommands.count

        let sp50 = percentile(sessions, 0.50)
        let sp75 = percentile(sessions, 0.75)
        let sp95 = percentile(sessions, 0.95)
        let vp50 = percentile(savingsPct, 0.50)
        let vp95 = percentile(savingsPct, 0.95)

        let line = String(
            format: "[compound_learning] proposals=%d sessions_p50=%.0f p75=%.0f p95=%.0f savedpct_p50=%.1f p95=%.1f\n",
            n, sp50, sp75, sp95, vp50, vp95
        )
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Linear-interpolation percentile for a sorted numeric array.
    /// Double-valued so we can pass `[Int]` or `[Double]` uniformly.
    private static func percentile<T: BinaryFloatingPoint>(_ sorted: [T], _ q: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let n = sorted.count
        let pos = q * Double(n - 1)
        let lo = Int(pos.rounded(.down))
        let hi = Int(pos.rounded(.up))
        if lo == hi { return Double(sorted[lo]) }
        let frac = pos - Double(lo)
        return (1 - frac) * Double(sorted[lo]) + frac * Double(sorted[hi])
    }
    private static func percentile(_ sorted: [Int], _ q: Double) -> Double {
        percentile(sorted.map { Double($0) } as [Double], q)
    }
}
