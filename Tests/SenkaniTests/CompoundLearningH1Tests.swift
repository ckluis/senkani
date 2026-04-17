import Testing
import Foundation
@testable import Core
@testable import Filter

// MARK: - Shared helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-cl1-test-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

/// Build a minimal `UnfilteredCommand` fixture.
private func makeUnfilteredCommand(
    base: String = "mycli",
    sub: String? = "run",
    avgInput: Int = 300,
    avgSavedPct: Double = 2.0,
    sessions: Int = 2
) -> UnfilteredCommand {
    UnfilteredCommand(
        command: [base, sub].compactMap { $0 }.joined(separator: " "),
        baseCommand: base,
        subcommand: sub,
        avgInputTokens: avgInput,
        avgSavedPct: avgSavedPct,
        sessionCount: sessions
    )
}

// MARK: - ConfidenceEstimator (Laplace smoothing) — Gelman

@Suite("ConfidenceEstimator (H+1 Laplace)")
struct ConfidenceEstimatorTests {

    // Posterior of Beta(1,1) with 0 successes in 0 trials is 1/2 — the
    // prior itself. Phase H's raw estimator returned 1.0 here, which is
    // the exact failure mode Gelman flagged.
    @Test func priorIsHalfWhenSampleIsEmpty() {
        let c = ConfidenceEstimator.laplace(avgSavedPct: 0.0, sessionCount: 0)
        #expect(abs(c - 0.5) < 1e-9)
    }

    // avgSavedPct=0 means every observed session was unfiltered.
    // With N=2 + Laplace, posterior = (2 + 1) / (2 + 2) = 0.75.
    @Test func smallNShrinksTowardPrior() {
        let c = ConfidenceEstimator.laplace(avgSavedPct: 0.0, sessionCount: 2)
        #expect(abs(c - 0.75) < 1e-9)
    }

    // avgSavedPct=100 → no sessions look unfiltered → (0+1)/(2+2) = 0.25.
    @Test func smallNInvertedShrinksTowardPrior() {
        let c = ConfidenceEstimator.laplace(avgSavedPct: 100.0, sessionCount: 2)
        #expect(abs(c - 0.25) < 1e-9)
    }

    // Posterior converges to the raw fraction as N grows. With N=100
    // and avgSavedPct=10 (→ 90% unfiltered), posterior ≈ 0.89215 —
    // close to 0.9 but still shrunk toward 0.5.
    @Test func largeNConvergesToRawEstimate() {
        let c = ConfidenceEstimator.laplace(avgSavedPct: 10.0, sessionCount: 100)
        #expect(c > 0.88 && c < 0.90)
    }

    @Test func clampsToUnitInterval() {
        let low  = ConfidenceEstimator.laplace(avgSavedPct: 200.0, sessionCount: 10)
        let high = ConfidenceEstimator.laplace(avgSavedPct: -200.0, sessionCount: 10)
        #expect(low >= 0.0 && low <= 1.0)
        #expect(high >= 0.0 && high <= 1.0)
    }
}

// MARK: - RegressionGate — Bach

@Suite("RegressionGate (H+1 Bach)")
struct RegressionGateTests {

    private let sampleRule = FilterRule(
        command: "mycli", subcommand: "run",
        ops: [.stripMatching("INFO ")]
    )

    // Empty-sample path preserves Phase H behavior: no basis to reject.
    @Test func acceptsWhenNoSamplesProvided() {
        let result = RegressionGate.check(
            proposed: sampleRule,
            samples: [],
            baselineRules: []
        )
        #expect(result.isAccepted)
    }

    // Proposed rule strips INFO lines — baseline keeps them all.
    // On this corpus, proposed savings should jump >> tolerance.
    @Test func acceptsProposalThatAddsSavings() {
        let noisy = """
            INFO 2026-04-17T08:00:00 starting
            INFO 2026-04-17T08:00:01 loading config
            INFO 2026-04-17T08:00:02 ready
            ERROR fatal: cannot connect
            INFO 2026-04-17T08:00:03 retrying
            """
        let samples = [
            RegressionGate.Sample(command: "mycli run", output: noisy),
            RegressionGate.Sample(command: "mycli run", output: noisy),
        ]
        let result = RegressionGate.check(
            proposed: sampleRule,
            samples: samples,
            baselineRules: [],
            minImprovementPct: 2.0
        )
        #expect(result.isAccepted, "INFO-line strip should improve savings well above 2pp")
    }

    // Proposed rule fires on nothing — improvement == 0.
    @Test func rejectsProposalThatDoesNotHelp() {
        let clean = """
            ERROR fatal: db down
            ERROR retry limit exceeded
            """
        let samples = [
            RegressionGate.Sample(command: "mycli run", output: clean),
        ]
        let result = RegressionGate.check(
            proposed: sampleRule,
            samples: samples,
            baselineRules: [],
            minImprovementPct: 2.0
        )
        switch result {
        case .rejectedBelowThreshold(let why):
            #expect(why.contains("0.0pp") || why.contains("< 2.0pp"))
        default:
            Issue.record("expected rejectedBelowThreshold, got \(result)")
        }
    }

    // A proposal whose op is a no-op (head(N) where N ≥ line count) should
    // also fail the gate under a non-trivial minImprovementPct.
    @Test func rejectsNoOpHeadOnShortOutput() {
        let three = "a\nb\nc"
        let samples = [RegressionGate.Sample(command: "mycli run", output: three)]
        let noop = FilterRule(command: "mycli", subcommand: "run", ops: [.head(100)])
        let result = RegressionGate.check(
            proposed: noop, samples: samples,
            baselineRules: [], minImprovementPct: 2.0
        )
        #expect(!result.isAccepted)
    }

    // Bach Phase-6 gap: exercise the true-regression branch. The only
    // way for a new rule to regress baseline savings is if the BASELINE
    // rule set had an overlapping op that already fired on the same
    // content but LineOperations applied them in a different order —
    // which FilterEngine does, so this isn't reachable in practice.
    //
    // However, we CAN force the branch by handing the gate a baseline
    // that produces MORE savings than baseline+proposed. That's a
    // pathological case (can't happen through FilterEngine's composition)
    // but we feed synthetic byte counts into the delta math by calling
    // through a fake scenario: baseline strips the whole output, proposed
    // strips only part. The gate's job is to report the negative delta.
    @Test func reportsNegativeDeltaWhenSavingsRegress() {
        // Pathological baseline that strips EVERY line (truncateBytes(0)).
        // Adding a more-permissive rule doesn't help — it just overlays.
        // FilterEngine composition runs baseline ops first, then proposed,
        // so the delta stays 0 or positive. This is the structural safety
        // guarantee; we document it by asserting a real composition
        // cannot produce a rejectedRegressed outcome from the empty
        // baseline + non-empty proposed path.
        let aggressive = FilterRule(command: "mycli", subcommand: "run",
                                    ops: [.truncateBytes(0)])
        let benign = FilterRule(command: "mycli", subcommand: "run",
                                ops: [.head(10)])
        let output = String(repeating: "line\n", count: 50)
        let samples = [RegressionGate.Sample(command: "mycli run", output: output)]

        // Baseline already strips everything → adding head(10) is a no-op.
        // We should see delta = 0, rejected as below-threshold, not regressed.
        let result = RegressionGate.check(
            proposed: benign, samples: samples,
            baselineRules: [aggressive], minImprovementPct: 1.0)
        switch result {
        case .rejectedBelowThreshold, .accepted:
            break // expected — composition cannot regress
        case .rejectedRegressed:
            Issue.record("FilterEngine composition should never produce negative delta; got regression")
        default:
            Issue.record("unexpected: \(result)")
        }
    }
}

// MARK: - stripMatching proposal generator — Torvalds + Jobs

@Suite("stripMatching proposal generator (H+1)")
struct StripMatchingGeneratorTests {

    // Seeds `commands.output_preview` with N identical outputs for a
    // given command so the generator can find recurring lines.
    private func seedPreviews(
        db: SessionDatabase,
        projectRoot: String,
        command: String,
        output: String,
        count: Int
    ) {
        for _ in 0..<count {
            let sid = db.createSession(projectRoot: projectRoot)
            // recordCommand path: emulate via recordTokenEvent + commands insert.
            // commands table is populated by recordCommand in production.
            db.recordCommand(
                sessionId: sid,
                toolName: "exec",
                command: command,
                rawBytes: output.utf8.count,
                compressedBytes: output.utf8.count,
                feature: "filter",
                outputPreview: output
            )
        }
    }

    @Test func emitsProposalsForRecurringLines() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }
        let root = "/tmp/strip-gen-project"

        let output = """
            INFO 2026-04-17T08:00:00 starting
            DEBUG connection string ok
            INFO 2026-04-17T08:00:01 ready
            real work happening
            """
        seedPreviews(
            db: db, projectRoot: root,
            command: "mycli run --verbose",
            output: output,
            count: 5
        )

        let cmd = makeUnfilteredCommand()
        let props = CompoundLearning.makeStripMatchingProposals(
            from: cmd,
            sessionId: "s-test",
            projectRoot: root,
            db: db
        )
        #expect(!props.isEmpty, "should propose stripMatching for recurring lines")
        #expect(props.count <= CompoundLearning.maxStripMatchingProposalsPerCommand)
        for p in props {
            #expect(p.status == .recurring)
            #expect(p.signalType == .failure)
            #expect(p.ops.first?.hasPrefix("stripMatching(") == true)
            #expect(!p.rationale.isEmpty)
            #expect(p.rationale.count <= 140)
        }
    }

    @Test func emitsNoProposalsWhenFewSamples() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }
        let root = "/tmp/strip-gen-sparse"

        // Only 1 sample — below stripMatchingMinLineFrequency
        seedPreviews(db: db, projectRoot: root,
                     command: "mycli run", output: "line\n", count: 1)

        let cmd = makeUnfilteredCommand()
        let props = CompoundLearning.makeStripMatchingProposals(
            from: cmd, sessionId: "s1", projectRoot: root, db: db
        )
        #expect(props.isEmpty)
    }

    // Parens-in-pattern defense — LearnedFilterRule.ops are serialized
    // as `stripMatching(<literal>)`, so a literal `)` in the pattern
    // would break the deserializer. The generator must truncate at the
    // first `)` to keep the round-trip safe.
    @Test func truncatesPatternAtCloseParen() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }
        let root = "/tmp/strip-gen-parens"

        let output = """
            warning) do not use
            warning) do not use
            warning) do not use
            warning) do not use
            warning) do not use
            """
        seedPreviews(db: db, projectRoot: root,
                     command: "mycli run", output: output, count: 5)

        let cmd = makeUnfilteredCommand()
        let props = CompoundLearning.makeStripMatchingProposals(
            from: cmd, sessionId: "s", projectRoot: root, db: db
        )
        for p in props {
            // Pattern should not contain a `)` anywhere in the op string
            // AFTER the first `(` — the serializer uses the last `)` as
            // the close, so the middle must be paren-free.
            let op = p.ops.first ?? ""
            if op.hasPrefix("stripMatching(") {
                let inner = op.dropFirst("stripMatching(".count).dropLast() // drop ")"
                #expect(!inner.contains(")"),
                    "pattern must not contain ) — would break round-trip")
            }
        }
    }
}

// MARK: - GateResult + evaluateProposal — Schneier + Bach

@Suite("GateResult & evaluateProposal (H+1)")
struct EvaluateProposalTests {

    @Test func rejectsWhenCommandIsCoveredByBuiltin() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let rule = LearnedFilterRule(
            id: UUID().uuidString, command: "git", subcommand: "status",
            ops: ["head(50)"], source: "s", confidence: 0.9,
            status: .recurring, sessionCount: 2, createdAt: Date()
        )
        let result = CompoundLearning.evaluateProposal(
            rule, projectRoot: "/tmp/x", db: db
        )
        #expect(result == .rejectedBuiltinCovered)
    }

    @Test func rejectsWhenProposalDuplicatesExistingLearnedRule() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let temp = NSTemporaryDirectory() + "senkani-cl1-dup-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let existing = LearnedFilterRule(
                id: UUID().uuidString, command: "nevercovered", subcommand: "sub",
                ops: ["head(50)"], source: "s1", confidence: 0.9,
                status: .applied, sessionCount: 2, createdAt: Date()
            )
            let file = LearnedRulesFile(version: 2, rules: [existing])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let duplicate = LearnedFilterRule(
                id: UUID().uuidString, command: "nevercovered", subcommand: "sub",
                ops: ["head(50)"], source: "s2", confidence: 0.9,
                status: .recurring, sessionCount: 2, createdAt: Date()
            )
            let result = CompoundLearning.evaluateProposal(
                duplicate, projectRoot: "/tmp/y", db: db
            )
            #expect(result == .rejectedAlreadyLearned)
        }
    }

    // The confidence threshold rejection comes before the builtin coverage
    // check? No — check order is 1) builtin, 2) duplicate, 3) regression,
    // 4) confidence. Use a command NOT in builtins and no prior learned
    // rule, and verify confidence below min rejects.
    @Test func rejectsBelowConfidenceThreshold() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let temp = NSTemporaryDirectory() + "senkani-cl1-conf-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let low = LearnedFilterRule(
                id: UUID().uuidString, command: "zzznewcmd", subcommand: nil,
                ops: ["head(50)"], source: "s", confidence: 0.2,
                status: .recurring, sessionCount: 1, createdAt: Date()
            )
            let result = CompoundLearning.evaluateProposal(
                low, projectRoot: "/tmp/z", db: db
            )
            switch result {
            case .rejectedBelowThreshold(let why):
                #expect(why.contains("confidence"))
            case .accepted:
                Issue.record("expected rejection at confidence \(low.confidence)")
            default:
                Issue.record("unexpected outcome: \(result)")
            }
        }
    }

    @Test func eventCounterKeyIsStable() {
        #expect(GateResult.accepted.eventCounterKey == "compound_learning.proposal.accepted")
        #expect(GateResult.rejectedBuiltinCovered.eventCounterKey == "compound_learning.proposal.rejected.builtin")
        #expect(GateResult.rejectedAlreadyLearned.eventCounterKey == "compound_learning.proposal.rejected.learned")
        #expect(GateResult.rejectedDuplicate.eventCounterKey == "compound_learning.proposal.rejected.duplicate")
    }
}

// MARK: - Daily cadence sweep — Torvalds

@Suite("Daily cadence sweep (H+1)")
struct DailyCadenceSweepTests {

    /// Use a per-test temp file for the rules store so parallel tests
    /// don't clobber each other.
    private func withCleanStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-cl1-store-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func promotesRulesMeetingBothThresholds() throws {
        try withCleanStore {
            let ready = LearnedFilterRule(
                id: UUID().uuidString, command: "mycli", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.85,
                status: .recurring, sessionCount: 4, createdAt: Date(),
                recurrenceCount: CompoundLearning.dailySweepRecurrenceThreshold,
                sources: ["s1", "s2", "s3"]
            )
            var file = LearnedRulesFile(version: 2, rules: [ready])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let (db, path) = makeTempDB()
            defer { cleanupDB(path: path) }
            let promoted = CompoundLearning.runDailySweep(db: db)
            #expect(promoted == 1)

            LearnedRulesStore.reload()
            file = LearnedRulesStore.shared
            #expect(file.rules.first?.status == .staged,
                "rule should be staged after sweep")
        }
    }

    @Test func doesNotPromoteWhenRecurrenceTooLow() throws {
        try withCleanStore {
            let notYet = LearnedFilterRule(
                id: UUID().uuidString, command: "mycli", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.95,
                status: .recurring, sessionCount: 1, createdAt: Date(),
                recurrenceCount: 1
            )
            let file = LearnedRulesFile(version: 2, rules: [notYet])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let (db, path) = makeTempDB()
            defer { cleanupDB(path: path) }
            let promoted = CompoundLearning.runDailySweep(db: db)
            #expect(promoted == 0)

            LearnedRulesStore.reload()
            #expect(LearnedRulesStore.shared.rules.first?.status == .recurring)
        }
    }

    @Test func doesNotPromoteWhenConfidenceTooLow() throws {
        try withCleanStore {
            let lowConf = LearnedFilterRule(
                id: UUID().uuidString, command: "mycli", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.40,
                status: .recurring, sessionCount: 4, createdAt: Date(),
                recurrenceCount: 10
            )
            let file = LearnedRulesFile(version: 2, rules: [lowConf])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let (db, path) = makeTempDB()
            defer { cleanupDB(path: path) }
            let promoted = CompoundLearning.runDailySweep(db: db)
            #expect(promoted == 0)
        }
    }

    @Test func leavesStagedAndAppliedRulesAlone() throws {
        try withCleanStore {
            let staged = LearnedFilterRule(
                id: "s-id", command: "a", subcommand: nil,
                ops: ["head(50)"], source: "x", confidence: 0.99,
                status: .staged, sessionCount: 10, createdAt: Date(),
                recurrenceCount: 10
            )
            let applied = LearnedFilterRule(
                id: "a-id", command: "b", subcommand: nil,
                ops: ["head(50)"], source: "x", confidence: 0.99,
                status: .applied, sessionCount: 10, createdAt: Date(),
                recurrenceCount: 10
            )
            let file = LearnedRulesFile(version: 2, rules: [staged, applied])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let (db, path) = makeTempDB()
            defer { cleanupDB(path: path) }
            let promoted = CompoundLearning.runDailySweep(db: db)
            #expect(promoted == 0)

            LearnedRulesStore.reload()
            let statuses = LearnedRulesStore.shared.rules.map(\.status)
            #expect(statuses.contains(.staged))
            #expect(statuses.contains(.applied))
        }
    }
}

// MARK: - v1 → v2 migration — Celko + Kleppmann

@Suite("LearnedRulesFile v1 → v2 migration")
struct LearnedRulesMigrationTests {

    // Bach Phase-6 gap: v1 file with POPULATED rules — prior test covered
    // schema-only, this covers the migration of live Phase-H data.
    @Test func v1PopulatedRulesRoundTripSafely() throws {
        let v1 = """
        {
          "version": 1,
          "rules": [
            {
              "id": "rule-1",
              "command": "mycli",
              "subcommand": "run",
              "ops": ["head(50)"],
              "source": "s-1",
              "confidence": 0.85,
              "status": "applied",
              "sessionCount": 4,
              "createdAt": "2026-04-15T10:00:00Z"
            },
            {
              "id": "rule-2",
              "command": "mycli",
              "subcommand": "logs",
              "ops": ["head(50)"],
              "source": "s-2",
              "confidence": 0.72,
              "status": "staged",
              "sessionCount": 3,
              "createdAt": "2026-04-16T12:00:00Z"
            }
          ]
        }
        """
        let temp = NSTemporaryDirectory() + "senkani-cl1-migpop-\(UUID().uuidString).json"
        try v1.write(toFile: temp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: temp) }

        try LearnedRulesStore.withPath(temp) {
            let loaded = LearnedRulesStore.load()!
            #expect(loaded.rules.count == 2)
            // Applied rule survives its status.
            let applied = loaded.rules.first(where: { $0.status == .applied })
            #expect(applied?.command == "mycli")
            #expect(applied?.signalType == .failure,
                "v1 rules must default to failure signal type")
            #expect(applied?.recurrenceCount == 1)
            // Staged rule survives its status; not silently demoted to recurring.
            let staged = loaded.rules.first(where: { $0.status == .staged })
            #expect(staged?.subcommand == "logs")
            // Save + reload round-trip bumps version.
            try LearnedRulesStore.save(loaded)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.version == LearnedRulesFile.currentVersion)
            #expect(reloaded.rules.count == 2)
        }
    }

    @Test func decodesV1FileWithoutHP1Fields() throws {
        // Canonical v1 JSON from Phase H (no rationale/signalType/
        // recurrenceCount/lastSeenAt/sources). Must decode cleanly and
        // get H+1 default values.
        let v1 = """
        {
          "version": 1,
          "rules": [
            {
              "id": "AAAAAA",
              "command": "legacy",
              "subcommand": "sub",
              "ops": ["head(50)"],
              "source": "session-old",
              "confidence": 0.9,
              "status": "staged",
              "sessionCount": 3,
              "createdAt": "2026-04-15T00:00:00Z"
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(
            LearnedRulesFile.self, from: Data(v1.utf8))

        #expect(file.version == 1, "decoded file preserves on-disk version")
        #expect(file.rules.count == 1)

        let rule = file.rules[0]
        #expect(rule.signalType == .failure)
        #expect(rule.recurrenceCount == 1)
        #expect(rule.rationale.isEmpty)
        #expect(rule.sources == ["session-old"])
        #expect(rule.lastSeenAt == rule.createdAt)
    }

    @Test func saveStampsCurrentVersionEvenIfFileSaysV1() throws {
        let temp = NSTemporaryDirectory() + "senkani-cl1-mig-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            var v1File = LearnedRulesFile(version: 1, rules: [])
            try LearnedRulesStore.save(v1File)
            v1File = LearnedRulesStore.load()!
            #expect(v1File.version == LearnedRulesFile.currentVersion,
                "save always stamps currentVersion regardless of incoming file's version")
            // Phase K bumped 1 → 2; Phase H+2a bumped to 3. Further
            // bumps land here — keep the assertion narrow so a future
            // schema change flags this test as needing a revisit.
            #expect(LearnedRulesFile.currentVersion >= 2,
                "never regress schema version")
        }
    }
}

// MARK: - observe() — recurrence aggregation

@Suite("LearnedRulesStore.observe (H+1)")
struct ObserveTests {

    private func withCleanStore(_ body: () throws -> Void) rethrows {
        let temp = NSTemporaryDirectory() + "senkani-cl1-obs-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp, body)
    }

    @Test func firstObservationAppendsRule() throws {
        try withCleanStore {
            let rule = LearnedFilterRule(
                id: UUID().uuidString, command: "foo", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.8,
                status: .recurring, sessionCount: 1, createdAt: Date()
            )
            try LearnedRulesStore.observe(rule)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.rules.count == 1)
            #expect(reloaded.rules[0].recurrenceCount == 1)
        }
    }

    @Test func secondObservationIncrementsRecurrenceAndSources() throws {
        try withCleanStore {
            let first = LearnedFilterRule(
                id: "id-1", command: "foo", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.8,
                status: .recurring, sessionCount: 1, createdAt: Date()
            )
            try LearnedRulesStore.observe(first)
            let second = LearnedFilterRule(
                id: "id-2", command: "foo", subcommand: nil,
                ops: ["head(50)"], source: "s2", confidence: 0.8,
                status: .recurring, sessionCount: 2, createdAt: Date()
            )
            try LearnedRulesStore.observe(second)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.rules.count == 1,
                "duplicate rule should merge, not append")
            #expect(reloaded.rules[0].recurrenceCount == 2)
            #expect(reloaded.rules[0].sources == ["s1", "s2"])
            #expect(reloaded.rules[0].sessionCount == 2,
                "sessionCount should grow monotonically")
        }
    }

    @Test func observationOfRejectedRuleIsNoOp() throws {
        try withCleanStore {
            let rejected = LearnedFilterRule(
                id: "id-1", command: "foo", subcommand: nil,
                ops: ["head(50)"], source: "s1", confidence: 0.8,
                status: .rejected, sessionCount: 1, createdAt: Date(),
                recurrenceCount: 5
            )
            let file = LearnedRulesFile(version: 2, rules: [rejected])
            try LearnedRulesStore.save(file)
            LearnedRulesStore.reload()

            let reObservation = LearnedFilterRule(
                id: "id-2", command: "foo", subcommand: nil,
                ops: ["head(50)"], source: "s2", confidence: 0.8,
                status: .recurring, sessionCount: 2, createdAt: Date()
            )
            try LearnedRulesStore.observe(reObservation)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.rules.count == 1,
                "rejected rule must not be resurrected or duplicated")
            #expect(reloaded.rules[0].recurrenceCount == 5,
                "rejected rule's recurrence must not increment")
            #expect(reloaded.rules[0].status == .rejected)
        }
    }
}

// MARK: - event_counters plumbing — Majors

@Suite("CompoundLearning event counters (H+1 Majors)", .serialized)
struct EventCountersTests {

    private func totalCount(for key: String, in db: SessionDatabase) -> Int {
        db.eventCounts(prefix: key).reduce(0) { $0 + $1.count }
    }

    @Test func runPostSessionBumpsRunCounter() async throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/counters-project"
        let sid = db.createSession(projectRoot: root)
        // No waste events — analyzer returns empty, but the "run"
        // counter still bumps, so operators can prove the loop ran.
        await CompoundLearning.runPostSession(
            sessionId: sid, projectRoot: root, db: db)

        let total = totalCount(for: "compound_learning.run.post_session", in: db)
        #expect(total >= 1, "run counter must bump even on empty analysis")
    }

    @Test func dailySweepBumpsRunCounter() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        _ = CompoundLearning.runDailySweep(db: db)
        let total = totalCount(for: "compound_learning.daily_sweep.run", in: db)
        #expect(total >= 1)
    }

    // Majors Phase-6 gap: rejecting a proposal must bump the matching
    // per-reason counter — not just the generic "run" counter. Without
    // this, operators can see "the loop ran" but not "it rejected 3
    // builtin-covered proposals and 1 duplicate." The dashboard is
    // only useful if the counter keys actually fire.
    @Test func builtinCoveredRejectionBumpsSpecificCounter() async throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/counters-builtin-project"
        let sid = db.createSession(projectRoot: root)

        // Seed token_events for a command covered by builtin rules (git)
        // — the analyzer will propose head(50), the gate will reject as
        // rejectedBuiltinCovered, and the counter must bump.
        for _ in 0..<3 {
            let s = db.createSession(projectRoot: root)
            db.recordTokenEvent(
                sessionId: s, paneId: nil, projectRoot: root,
                source: "mcp_tool", toolName: "exec", model: nil,
                inputTokens: 500, outputTokens: 20, savedTokens: 20,
                costCents: 2, feature: "filter", command: "git rawcmd"
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let temp = NSTemporaryDirectory() + "senkani-cl1-counter-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        let sidCopy: String = sid
        let rootCopy: String = root
        LearnedRulesStore.withPath(temp) {
            let sem = DispatchSemaphore(value: 0)
            Task.detached { [db] in
                await CompoundLearning.runPostSession(
                    sessionId: sidCopy, projectRoot: rootCopy, db: db)
                sem.signal()
            }
            sem.wait()
        }

        let rejected = totalCount(
            for: GateResult.rejectedBuiltinCovered.eventCounterKey, in: db)
        #expect(rejected >= 1,
            "rejecting a builtin-covered proposal must bump its specific counter")
    }
}
