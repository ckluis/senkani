import Testing
import Foundation
@testable import Core

private final class ResultBox<U>: @unchecked Sendable {
    var value: U?
}

/// Helper: block the current thread on a `Task.value`. Swift 6 blocks
/// NSLock across `await`, so tests that need path isolation for an
/// async body wrap the body in a `Task.detached` and use this to
/// synchronously wait for completion while holding `withPath`'s lock.
private func blockingWait<T: Sendable>(_ task: Task<T, Never>) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        box.value = await task.value
        sem.signal()
    }
    sem.wait()
    return box.value!
}

// MARK: - Mock RationaleLLM

/// Stub that returns a caller-configured output. Used to exercise
/// success / failure / oversized / empty paths without loading MLX.
private final class MockRationaleLLM: RationaleLLM, @unchecked Sendable {
    enum Behavior: Sendable {
        case success(String)
        case fail(RationaleLLMError)
    }
    let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }
    func rewrite(prompt: String) async throws -> String {
        switch behavior {
        case .success(let s): return s
        case .fail(let e): throw e
        }
    }
}

// MARK: - Fixture

private func sampleRule(
    id: String = UUID().uuidString,
    rationale: String = "docker/compose: 4 sessions, avg 2% saved — head(50) caps runaway output."
) -> LearnedFilterRule {
    LearnedFilterRule(
        id: id,
        command: "docker",
        subcommand: "compose",
        ops: ["head(50)"],
        source: "s-1",
        confidence: 0.8,
        status: .staged,
        sessionCount: 4,
        createdAt: Date(timeIntervalSince1970: 1_713_360_000),
        rationale: rationale,
        signalType: .failure,
        recurrenceCount: 4
    )
}

// MARK: - GemmaRationaleRewriter (Karpathy coverage)

@Suite("GemmaRationaleRewriter (H+2a Karpathy)")
struct GemmaRationaleRewriterTests {

    @Test func happyPathReturnsTrimmedSingleLine() async {
        let llm = MockRationaleLLM(.success("  Strips routine docker output to surface errors.\n"))
        let r = GemmaRationaleRewriter(llm: llm)
        let text = await r.enrich(sampleRule())
        #expect(text == "Strips routine docker output to surface errors.",
            "trimmed, single-line, lossless happy path")
    }

    @Test func nilWhenLLMUnavailable() async {
        let r = GemmaRationaleRewriter(llm: MockRationaleLLM(.fail(.unavailable)))
        #expect(await r.enrich(sampleRule()) == nil)
    }

    @Test func nilWhenLLMErrors() async {
        let r = GemmaRationaleRewriter(llm: MockRationaleLLM(.fail(.invalidResponse("boom"))))
        #expect(await r.enrich(sampleRule()) == nil)
    }

    @Test func nilWhenLLMReturnsEmpty() async {
        let r = GemmaRationaleRewriter(llm: MockRationaleLLM(.success("   \n\t")))
        #expect(await r.enrich(sampleRule()) == nil,
            "whitespace-only LLM output must fall back to nil")
    }

    @Test func outputCappedToConfiguredMax() async {
        let huge = String(repeating: "a ", count: 1000) // 2000 chars
        let r = GemmaRationaleRewriter(
            llm: MockRationaleLLM(.success(huge)), maxOutputChars: 80)
        let text = await r.enrich(sampleRule())
        guard let t = text else { Issue.record("expected non-nil"); return }
        #expect(t.count <= 80)
    }

    @Test func newlinesCollapseToSpaces() async {
        let r = GemmaRationaleRewriter(
            llm: MockRationaleLLM(.success("first line.\n\nsecond\tline."))
        )
        let text = await r.enrich(sampleRule())
        #expect(text == "first line. second line.")
    }

    @Test func secretsInLLMOutputAreRedacted() async {
        let anthropicKey = "sk-ant-api03-" + String(repeating: "X", count: 85)
        let r = GemmaRationaleRewriter(
            llm: MockRationaleLLM(.success("Noise stripped; also leaked \(anthropicKey) here."))
        )
        let text = await r.enrich(sampleRule())
        guard let t = text else { Issue.record("expected non-nil"); return }
        #expect(!t.contains(anthropicKey),
            "raw secret from LLM must not land in enrichedRationale")
    }

    @Test func promptContainsRuleFactsDeterministically() {
        let r = GemmaRationaleRewriter(llm: MockRationaleLLM(.success("")))
        let rule = sampleRule()
        let p = r.buildPrompt(for: rule)
        #expect(p.contains("docker"))
        #expect(p.contains("compose"))
        #expect(p.contains("head(50)"))
        // Two calls produce the same prompt (prompt determinism — the
        // LLM's non-determinism is the model's fault, not ours).
        #expect(p == r.buildPrompt(for: rule))
    }

    @Test func promptCappedAtConfiguredMaxBytes() {
        var rule = sampleRule()
        rule.rationale = String(repeating: "filler ", count: 1000) // 7000 chars
        let r = GemmaRationaleRewriter(
            llm: MockRationaleLLM(.success("")), maxPromptBytes: 1024)
        let p = r.buildPrompt(for: rule)
        #expect(p.utf8.count <= 1024)
    }
}

// MARK: - CompoundLearningConfig (Gelman + Lauret)

@Suite("CompoundLearningConfig (H+2a)")
struct CompoundLearningConfigTests {

    private func tempConfigPath() -> String {
        NSTemporaryDirectory() + "senkani-compound-\(UUID().uuidString).json"
    }

    @Test func defaultsWhenNoFileNoEnv() {
        let eff = CompoundLearningConfig.resolve(
            environment: [:],
            filePath: tempConfigPath()
        )
        #expect(eff.minConfidence == CompoundLearningConfig.codeDefault.minConfidence)
        #expect(eff.dailySweepRecurrenceThreshold == CompoundLearningConfig.codeDefault.dailySweepRecurrenceThreshold)
        #expect(eff.dailySweepConfidenceThreshold == CompoundLearningConfig.codeDefault.dailySweepConfidenceThreshold)
    }

    @Test func fileOverridesDefault() throws {
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try CompoundLearningConfig.save(
            CompoundLearningConfig(
                minConfidence: 0.75,
                dailySweepRecurrenceThreshold: 5,
                dailySweepConfidenceThreshold: 0.85
            ),
            at: path
        )
        let eff = CompoundLearningConfig.resolve(environment: [:], filePath: path)
        #expect(eff.minConfidence == 0.75)
        #expect(eff.dailySweepRecurrenceThreshold == 5)
        #expect(eff.dailySweepConfidenceThreshold == 0.85)
    }

    @Test func envOverridesFile() throws {
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try CompoundLearningConfig.save(
            CompoundLearningConfig(minConfidence: 0.50), at: path)
        let eff = CompoundLearningConfig.resolve(
            environment: ["SENKANI_COMPOUND_MIN_CONFIDENCE": "0.95"],
            filePath: path
        )
        #expect(eff.minConfidence == 0.95,
            "env must override file when both are set")
    }

    @Test func clampsOutOfRangeValues() {
        let eff = CompoundLearningConfig.resolve(
            environment: [
                "SENKANI_COMPOUND_MIN_CONFIDENCE": "2.0",   // over 1
                "SENKANI_COMPOUND_DAILY_CONFIDENCE": "-0.5", // under 0
                "SENKANI_COMPOUND_DAILY_RECURRENCE": "-3",   // < 1
            ],
            filePath: tempConfigPath()
        )
        #expect(eff.minConfidence == 1.0)
        #expect(eff.dailySweepConfidenceThreshold == 0.0)
        #expect(eff.dailySweepRecurrenceThreshold == 1)
    }

    @Test func malformedFileFallsBackToDefault() throws {
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "not json {".write(toFile: path, atomically: true, encoding: .utf8)
        let eff = CompoundLearningConfig.resolve(environment: [:], filePath: path)
        #expect(eff.minConfidence == CompoundLearningConfig.codeDefault.minConfidence,
            "malformed JSON must not crash the server")
    }
}

// MARK: - v2 → v3 migration (Celko)

@Suite("LearnedRulesFile v2 → v3 migration (H+2a)")
struct LearnedRulesV3MigrationTests {

    @Test func decodesV2FileWithoutEnrichedRationale() throws {
        // A canonical v2 file (everything H+1 shipped, nothing from H+2a).
        let v2 = """
        {
          "version": 2,
          "rules": [
            {
              "id": "RULE-1",
              "command": "docker",
              "subcommand": "compose",
              "ops": ["head(50)"],
              "source": "s-old",
              "confidence": 0.9,
              "status": "staged",
              "sessionCount": 5,
              "createdAt": "2026-04-15T10:00:00Z",
              "rationale": "docker/compose: 5 sessions — head(50) caps.",
              "signalType": "failure",
              "recurrenceCount": 5,
              "lastSeenAt": "2026-04-17T00:00:00Z",
              "sources": ["s-1","s-2","s-old"]
            }
          ]
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let file = try decoder.decode(LearnedRulesFile.self, from: Data(v2.utf8))
        #expect(file.rules.count == 1)
        #expect(file.rules[0].enrichedRationale == nil,
            "v2 rule without enrichedRationale must decode as nil")
        #expect(file.rules[0].rationale.contains("head(50)"),
            "v2 deterministic rationale survives migration")
    }

    @Test func saveStampsV3EvenIfFileWasV2() throws {
        let temp = NSTemporaryDirectory() + "senkani-h2a-mig-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let v2File = LearnedRulesFile(version: 2, rules: [])
            try LearnedRulesStore.save(v2File)
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.version == LearnedRulesFile.currentVersion,
                "save always stamps currentVersion regardless of incoming file")
            // Schema bumped 1→2 in H+1, 2→3 in H+2a, 3→4 in H+2b.
            // Keep the narrow "never regress" assertion so future schema
            // bumps still catch this test.
            #expect(LearnedRulesFile.currentVersion >= 3,
                "never regress past H+2a")
        }
    }

    @Test func enrichedRationaleRoundTrip() throws {
        let temp = NSTemporaryDirectory() + "senkani-h2a-rt-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let rule = LearnedFilterRule(
                id: "E1", command: "docker", subcommand: nil,
                ops: ["head(50)"], source: "s", confidence: 0.9,
                status: .staged, sessionCount: 3, createdAt: Date(),
                enrichedRationale: "Noise suppressor — lets error lines surface first."
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [rule]))
            LearnedRulesStore.reload()
            let reloaded = LearnedRulesStore.load()!
            #expect(reloaded.rules[0].enrichedRationale ==
                "Noise suppressor — lets error lines surface first.")
        }
    }

    @Test func setEnrichedRationaleUpdatesSingleRule() throws {
        let temp = NSTemporaryDirectory() + "senkani-h2a-set-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let a = LearnedFilterRule(
                id: "A", command: "cmd-a", subcommand: nil,
                ops: ["head(50)"], source: "s", confidence: 0.9,
                status: .staged, sessionCount: 3, createdAt: Date()
            )
            let b = LearnedFilterRule(
                id: "B", command: "cmd-b", subcommand: nil,
                ops: ["head(50)"], source: "s", confidence: 0.9,
                status: .staged, sessionCount: 3, createdAt: Date()
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [a, b]))
            LearnedRulesStore.reload()

            try LearnedRulesStore.setEnrichedRationale(id: "A", text: "only-A")
            let reloaded = LearnedRulesStore.load()!
            let aLoaded = reloaded.rules.first(where: { $0.id == "A" })
            let bLoaded = reloaded.rules.first(where: { $0.id == "B" })
            #expect(aLoaded?.enrichedRationale == "only-A")
            #expect(bLoaded?.enrichedRationale == nil)
        }
    }
}

// MARK: - Orchestration — daily sweep enrichment hook (Majors)

@Suite("Daily sweep enrichment hook (H+2a Majors)", .serialized)
struct DailySweepEnrichmentTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-h2a-sweep-\(UUID().uuidString)/senkani.db"
        return (SessionDatabase(path: path), path)
    }

    private func totalCount(for prefix: String, in db: SessionDatabase) -> Int {
        db.eventCounts(prefix: prefix).reduce(0) { $0 + $1.count }
    }

    /// Promotion path WITHOUT an enricher — counter must NOT bump, the
    /// enrichment pathway is strictly opt-in.
    @Test func noEnricherNoEnrichmentCounter() throws {
        let (db, dbPath) = makeTempDB()
        defer { try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent) }

        let temp = NSTemporaryDirectory() + "senkani-h2a-sweep1-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let rule = LearnedFilterRule(
                id: "R1", command: "mytool", subcommand: nil,
                ops: ["head(50)"], source: "s-1", confidence: 0.95,
                status: .recurring, sessionCount: 5,
                createdAt: Date(), recurrenceCount: 5
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [rule]))
            LearnedRulesStore.reload()

            let promoted = CompoundLearning.runDailySweep(db: db)
            #expect(promoted == 1)
            #expect(totalCount(for: "compound_learning.enrichment", in: db) == 0,
                "no enricher → no enrichment counters")
        }
    }

    /// With a supplied enricher, a detached Task fires and (eventually)
    /// bumps the success counter. Because the Task is async we poll the
    /// counter briefly — but the `queued` counter bumps synchronously.
    @Test func enricherBumpsQueuedCounterSynchronously() throws {
        let (db, dbPath) = makeTempDB()
        defer { try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent) }

        let temp = NSTemporaryDirectory() + "senkani-h2a-sweep2-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }
        try LearnedRulesStore.withPath(temp) {
            let rule = LearnedFilterRule(
                id: "R2", command: "mytool", subcommand: nil,
                ops: ["head(50)"], source: "s-1", confidence: 0.95,
                status: .recurring, sessionCount: 5,
                createdAt: Date(), recurrenceCount: 5
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [rule]))
            LearnedRulesStore.reload()

            let enricher = GemmaRationaleRewriter(
                llm: MockRationaleLLM(.fail(.unavailable)))
            _ = CompoundLearning.runDailySweep(db: db, enricher: enricher)

            #expect(totalCount(for: "compound_learning.enrichment.queued", in: db) >= 1,
                "enrichment queued bumps synchronously when enricher is supplied")
        }
    }

    @Test func enrichStagedRulesAwaitsEnrichment() async throws {
        let (db, dbPath) = makeTempDB()
        defer { try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent) }

        let temp = NSTemporaryDirectory() + "senkani-h2a-sweep3-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }

        try LearnedRulesStore.withPath(temp) {
            let rule = LearnedFilterRule(
                id: "R3", command: "mytool", subcommand: nil,
                ops: ["head(50)"], source: "s-1", confidence: 0.95,
                status: .staged, sessionCount: 5, createdAt: Date()
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [rule]))
            LearnedRulesStore.reload()

            let enricher = GemmaRationaleRewriter(
                llm: MockRationaleLLM(.success("One-sentence enrichment.")))
            // Swift 6: can't hold NSLock across await, so block on a
            // Task.value synchronously while we hold withPath's lock.
            let task = Task.detached { () -> Int in
                await CompoundLearning.enrichStagedRules(
                    enricher: enricher, db: db)
            }
            let n = blockingWait(task)
            #expect(n == 1)

            LearnedRulesStore.reload()
            let updated = LearnedRulesStore.shared.rules.first
            #expect(updated?.enrichedRationale == "One-sentence enrichment.")
        }
    }

    @Test func enrichStagedRulesSkipsAlreadyEnriched() async throws {
        let (db, dbPath) = makeTempDB()
        defer { try? FileManager.default.removeItem(
            atPath: (dbPath as NSString).deletingLastPathComponent) }

        let temp = NSTemporaryDirectory() + "senkani-h2a-sweep4-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: temp) }

        try LearnedRulesStore.withPath(temp) {
            let already = LearnedFilterRule(
                id: "R4", command: "mytool", subcommand: nil,
                ops: ["head(50)"], source: "s-1", confidence: 0.95,
                status: .staged, sessionCount: 5, createdAt: Date(),
                enrichedRationale: "previously enriched"
            )
            try LearnedRulesStore.save(LearnedRulesFile(version: 3, rules: [already]))
            LearnedRulesStore.reload()

            let enricher = GemmaRationaleRewriter(
                llm: MockRationaleLLM(.success("new enrichment")))
            let task = Task.detached { () -> Int in
                await CompoundLearning.enrichStagedRules(
                    enricher: enricher, db: db)
            }
            let n = blockingWait(task)
            #expect(n == 0,
                "already-enriched rules must not be re-enriched")

            LearnedRulesStore.reload()
            #expect(LearnedRulesStore.shared.rules.first?.enrichedRationale == "previously enriched")
        }
    }
}
