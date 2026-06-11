import Testing
import Foundation
@testable import Core

/// Tests for the T.2a infrastructure round (PIIClassifier registry +
/// BIOES/Viterbi decoder + adapter shell). Layer 3 wiring into
/// `SecretDetector.FilterPipeline` is T.2b — there is no test for that
/// here because the wiring doesn't exist yet.
@Suite("PIIClassifier T.2a infrastructure")
struct PIIClassifierTests {

    // MARK: - Test helpers

    /// Spin up an isolated ModelManager pointed at a temp HF cache so the
    /// per-id verify and download flows don't trample whatever the real
    /// machine has cached.
    private func makeManager() -> (ModelManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pii-classifier-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let hfRoot = tempDir.appendingPathComponent("hf")
        let metadataURL = tempDir.appendingPathComponent("meta.json")
        try? FileManager.default.createDirectory(at: hfRoot, withIntermediateDirectories: true)
        return (ModelManager(hfCacheBase: hfRoot, metadataURL: metadataURL), hfRoot)
    }

    /// Minimal HF snapshot (config.json + dummy weight file) — same shape
    /// as `ModelManagerInstallTests.plantWeightsOnDisk` so the integrity
    /// default verifier accepts it.
    private func plantWeightsOnDisk(at hfRoot: URL, repoId: String) throws {
        let modelDir = hfRoot.appendingPathComponent(repoId)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let config = #"{"model_type":"test","hidden_size":64}"#.data(using: .utf8)!
        try config.write(to: modelDir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 32)
            .write(to: modelDir.appendingPathComponent("model.safetensors"))
    }

    /// Build a row of raw logits where `tag`'s slot dominates after
    /// softmax. The decoder softmaxes internally, so a logit of 10 on
    /// the winner vs 0 on the rest yields ≈0.998 probability — well
    /// above the 0.95 threshold our acceptance criteria cite.
    private func oneHotRow(tag: BIOESTag, winnerLogit: Float = 10.0) -> [Float] {
        let K = BIOESTag.tagCount
        var row = Array(repeating: Float(0), count: K)
        row[BIOESDecoder.rawIndex(tag)] = winnerLogit
        return row
    }

    /// Token alignment row whose char_offsets cover `text` starting at
    /// `start`. Used to drive the decoder with realistic offsets.
    private func alignment(_ text: String, start: Int) -> TokenAlignment {
        TokenAlignment(charStart: start, charEnd: start + text.count, text: text)
    }

    // MARK: - 1. Registry entry

    @Test("ModelManager registers pii-classifier-int8 with the correct repo id and INT8 quant")
    func registryHasPiiClassifierEntry() {
        let (mgr, _) = makeManager()
        let info = mgr.model("pii-classifier-int8")
        try? #require(info != nil)
        guard let info else { return }
        #expect(info.id == "pii-classifier-int8")
        #expect(info.repoId == "openai/privacy-filter")
        #expect(info.quantMethod == "INT8")
        #expect(info.requiredRAM == 4)
        // The default registry boots with .available — no auto-pull.
        #expect(info.status == .available)
    }

    // MARK: - 2. Decoder: empty input

    @Test("BIOES decoder emits no spans for an all-O sequence")
    func decoderEmitsNoSpansForBackgroundOnly() {
        let logits: [[Float]] = [
            oneHotRow(tag: .O),
            oneHotRow(tag: .O),
            oneHotRow(tag: .O),
        ]
        let alignments = [
            alignment("Hello", start: 0),
            alignment("world", start: 6),
            alignment(".", start: 11),
        ]
        let spans = BIOESDecoder.decode(logits: logits, alignments: alignments)
        #expect(spans.isEmpty)
    }

    // MARK: - 3. Decoder: single coherent span

    @Test("BIOES decoder collapses B-person … E-person into one private_person span")
    func decoderCollapsesMultiTokenPersonSpan() {
        let logits: [[Float]] = [
            oneHotRow(tag: .O),                        // "My"
            oneHotRow(tag: .O),                        // "name"
            oneHotRow(tag: .O),                        // "is"
            oneHotRow(tag: .B(.privatePerson)),        // "Harry"
            oneHotRow(tag: .E(.privatePerson)),        // "Potter"
        ]
        let alignments = [
            alignment("My",     start: 0),
            alignment("name",   start: 3),
            alignment("is",     start: 8),
            alignment("Harry",  start: 11),
            alignment("Potter", start: 17),
        ]
        let spans = BIOESDecoder.decode(logits: logits, alignments: alignments)
        #expect(spans.count == 1)
        guard let span = spans.first else { return }
        #expect(span.category == .privatePerson)
        #expect(span.charStart == 11)
        #expect(span.charEnd == 23)  // "Potter" ends at offset 23
        #expect(span.text == "Harry Potter")
        // Two-token average of ~0.99 per token rounds to ≥ 0.95.
        #expect(span.score > 0.95)
    }

    // MARK: - 4. Decoder: Viterbi rejects invalid B,B,B run

    @Test("Constrained Viterbi never emits three adjacent B-person tokens")
    func viterbiRejectsAdjacentBegins() {
        // Argmax-only would surface three B-person tags in a row. Viterbi
        // must rebalance: B → I or E only, so "B B B" is impossible. The
        // valid resolutions are S (single token), B-I-…-E (multi), or O.
        let logits: [[Float]] = [
            oneHotRow(tag: .B(.privatePerson)),
            oneHotRow(tag: .B(.privatePerson)),
            oneHotRow(tag: .B(.privatePerson)),
        ]
        let alignments = [
            alignment("Alice",   start: 0),
            alignment("Bob",     start: 6),
            alignment("Charlie", start: 10),
        ]
        let path = BIOESDecoder.viterbi(probs: logits.map(BIOESDecoder.softmax))
        #expect(path.count == 3)

        // No two adjacent tags in the path may be (B-X, B-X) and we must
        // never see three Bs running. Prove both via the transition table.
        for i in 0..<(path.count - 1) {
            #expect(BIOESTag.isTransitionAllowed(path[i], path[i+1]),
                    "transition at index \(i) is illegal: \(path[i]) → \(path[i+1])")
        }

        // The decoder's span output must NOT contain three single-token
        // person spans because the boundaries B-B-B are not satisfiable.
        // It may collapse to all-O or to a coherent single multi-token
        // span — either is acceptable. What's NOT acceptable is three Bs.
        let bTagCount = path.filter {
            if case .B = $0 { return true } else { return false }
        }.count
        #expect(bTagCount <= 1, "Viterbi emitted \(bTagCount) B-tags; expected at most 1")
    }

    // MARK: - 5. Decoder: S-tag single-token span

    @Test("BIOES decoder emits S-email as a single-token span with correct offsets")
    func decoderEmitsSingleTokenEmailSpan() {
        let logits: [[Float]] = [
            oneHotRow(tag: .O),
            oneHotRow(tag: .S(.privateEmail)),
            oneHotRow(tag: .O),
        ]
        let email = "harry.potter@hogwarts.edu"
        let alignments = [
            alignment("contact", start: 0),
            alignment(email,     start: 8),
            alignment("today",   start: 8 + email.count + 1),
        ]
        let spans = BIOESDecoder.decode(logits: logits, alignments: alignments)
        #expect(spans.count == 1)
        guard let span = spans.first else { return }
        #expect(span.category == .privateEmail)
        #expect(span.charStart == 8)
        #expect(span.charEnd == 8 + email.count)
        #expect(span.text == email)
        #expect(span.score > 0.95)
    }

    // MARK: - 6. CLI list — registry surfaces every entry

    @Test("ModelManager.models contains every expected default-registry entry including pii-classifier-int8")
    func registryListContainsExpectedEntries() {
        let (mgr, _) = makeManager()
        let ids = Set(mgr.models.map(\.id))
        // The classifier is the new entry T.2a registers — must surface
        // alongside the historic ids that `senkani models list` prints.
        #expect(ids.contains("pii-classifier-int8"))
        #expect(ids.contains("minilm-l6"))
        #expect(ids.contains("gemma4-e2b"))
    }

    // MARK: - 7. Verify status transition: verified → broken on tamper

    @Test("Re-verification flips .verified → .broken when the registered handler throws")
    func verifyRetryFlipsVerifiedToBroken() async throws {
        let (mgr, hfRoot) = makeManager()
        let modelId = "pii-classifier-int8"

        // Plant a snapshot so the integrity-only default would otherwise
        // pass; the test injects a verification handler that succeeds on
        // the first call, then throws on the second to simulate a tamper.
        try plantWeightsOnDisk(at: hfRoot, repoId: "openai/privacy-filter")

        let attempt = TestAtomic(0)
        mgr.registerDownloadHandler { id in
            // No-op — files are already on disk.
            mgr.markDownloaded(id)
        }
        mgr.registerVerificationHandler { _ in
            let n = attempt.increment()
            if n == 1 {
                return  // first verify passes
            }
            // second verify simulates tamper / corrupted weights
            throw NSError(
                domain: "test",
                code: 99,
                userInfo: [NSLocalizedDescriptionKey: "weights tampered"]
            )
        }

        try await mgr.download(modelId: modelId)
        #expect(mgr.model(modelId)?.status == .verified)

        // Second verify run trips the tamper path → .broken.
        await #expect(throws: Error.self) {
            try await mgr.verify(modelId: modelId)
        }
        #expect(mgr.model(modelId)?.status == .broken)
        #expect(mgr.model(modelId)?.lastError?.contains("tampered") == true)
    }

    // MARK: - 8. Adapter shell: T.2b backend gating

    @Test("PIIClassifierAdapter shell throws BackendNotReadyError until T.2b lands")
    func adapterShellThrowsUntilWired() async {
        // The adapter is a singleton; tests share it. Each entry point
        // must surface the staged-delivery marker so callers can give a
        // clean operator message.
        await #expect(throws: PIIClassifierAdapter.BackendNotReadyError.self) {
            try await PIIClassifierAdapter.shared.ensureModel()
        }
        await #expect(throws: PIIClassifierAdapter.BackendNotReadyError.self) {
            try await PIIClassifierAdapter.shared.runVerificationFixture()
        }
        await #expect(throws: PIIClassifierAdapter.BackendNotReadyError.self) {
            _ = try await PIIClassifierAdapter.shared.forward("Harry Potter")
        }
        // The adapter's modelId matches the registry id — single source of truth.
        #expect(PIIClassifierAdapter.modelId == "pii-classifier-int8")
    }
}

// MARK: - T.2 carve child B: gated real-spans suite

/// T.2 carve child B (`phase-t2-pii-realspans-tests-2026-06-09`) — pins the
/// classification CONTRACT (span detection + redaction shape) over real
/// PII-shaped fixtures: email, phone, SSN, and multi-token name. Every test
/// drives the REAL production decode path (`BIOESDecoder.decode` — softmax +
/// constrained Viterbi + span collapse) through the REAL `Layer3Inference`
/// seam shape and the REAL `PIISpanRedactor`, fed by deterministic one-hot
/// logits from a per-fixture token→tag rule map. 0 network, 0 model load,
/// 0 bytes of weights — the only thing stubbed is the logit source, which
/// is exactly the piece T.2b's MLX backend replaces.
///
/// ## Offline flag / skip-guard
///
/// The suite is gated on `SENKANI_PII_REAL_SPANS_REAL_MODEL`. Unset (the CI
/// and default-developer state) means OFFLINE: the deterministic rule path
/// runs and the assertions fire — green with zero HF pull. Setting the flag
/// to `1` declares "route these fixtures through the real model" — an arm
/// that does not exist until T.2b wires `PIIClassifierAdapter.forward`, so
/// the guard returns cleanly (a documented no-op skip, NEVER a model
/// download triggered from a test run). T.2b's takeover point is this
/// guard: replace the early return with the real tokenize → forward →
/// decode bridge and keep the identical fixture assertions.
@Suite("PIIClassifier real-span fixtures (T.2 carve child B, offline-gated)")
struct PIIClassifierRealSpansTests {

    // MARK: Offline gate

    /// Env flag name — operator opt-in for the future real-model arm.
    static let realModelFlag = "SENKANI_PII_REAL_SPANS_REAL_MODEL"

    /// True unless the operator explicitly opted into the real-model arm.
    /// CI never sets the flag, so the deterministic path always runs there.
    static var offline: Bool {
        ProcessInfo.processInfo.environment[realModelFlag] != "1"
    }

    // MARK: Deterministic rule path

    /// Build the deterministic rule path as a `Layer3Inference` — the SAME
    /// seam type `FilterPipeline.process` dispatches through — so the
    /// contract is pinned at the production call shape
    /// (`(text, threshold) → [PIISpan]`), not at a test-only signature.
    private func rulePath(tags: [String: BIOESTag]) -> Layer3Inference {
        // Single-space tokenizer with exact char offsets — token text at
        // [charStart, charEnd) always equals the source substring, mirroring
        // what a real tokenizer's char_offsets provide.
        let tokenizeLocal: @Sendable (String) -> [TokenAlignment] = { text in
            var alignments: [TokenAlignment] = []
            var start: Int? = nil
            var current = ""
            var offset = 0
            for ch in text {
                if ch == " " {
                    if let s = start {
                        alignments.append(TokenAlignment(charStart: s, charEnd: offset, text: current))
                        start = nil
                        current = ""
                    }
                } else {
                    if start == nil { start = offset }
                    current.append(ch)
                }
                offset += 1
            }
            if let s = start {
                alignments.append(TokenAlignment(charStart: s, charEnd: offset, text: current))
            }
            return alignments
        }
        return Layer3Inference { text, threshold in
            let alignments = tokenizeLocal(text)
            // One-hot row: winner logit 10 vs 0 elsewhere softmaxes to
            // ≈0.9986 — above the 0.85 general-pane floor with margin.
            let logits = alignments.map { token -> [Float] in
                var row = [Float](repeating: 0, count: BIOESTag.tagCount)
                row[BIOESDecoder.rawIndex(tags[token.text] ?? .O)] = 10.0
                return row
            }
            return BIOESDecoder.decode(logits: logits, alignments: alignments)
                .filter { $0.score >= Float(threshold) }
        }
    }

    /// Production general-pane softmax floor — the threshold the live
    /// pipeline passes for non-redteam panes.
    private var floor: Double { PaneMode.general.piiSensitivityThreshold }

    // MARK: 1. Email

    @Test("real email fixture: S-private_email span detected with exact offsets and redacted as PII_PRIVATE_EMAIL")
    func emailFixtureDetectsAndRedacts() throws {
        guard Self.offline else { return }  // real-model arm lands with T.2b — no download from a test run

        let email = "jane.doe+billing@acme-corp.io"
        let text = "Reach me at \(email) once the audit closes"
        let spans = try rulePath(tags: [email: .S(.privateEmail)])
            .detectSpans(text, floor)

        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.category == .privateEmail)
        #expect(span.charStart == 12)
        #expect(span.charEnd == 12 + email.count)
        #expect(span.text == email)
        #expect(span.score >= Float(floor) && span.score <= 1.0)

        let redaction = PIISpanRedactor.apply(spans: spans, to: text)
        #expect(redaction.redacted == "Reach me at [REDACTED:PII_PRIVATE_EMAIL] once the audit closes")
        #expect(redaction.patterns == ["PII_PRIVATE_EMAIL"])
        #expect(!redaction.redacted.contains("jane.doe"))
        #expect(!redaction.redacted.contains("acme-corp.io"))
    }

    // MARK: 2. Phone

    @Test("real phone fixture: B/E-private_phone tokens collapse to one span and redact as PII_PRIVATE_PHONE")
    func phoneFixtureCollapsesAndRedacts() throws {
        guard Self.offline else { return }  // real-model arm lands with T.2b — no download from a test run

        let text = "Call (415) 555-0184 before the window closes"
        let spans = try rulePath(tags: [
            "(415)":    .B(.privatePhone),
            "555-0184": .E(.privatePhone),
        ]).detectSpans(text, floor)

        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.category == .privatePhone)
        #expect(span.charStart == 5)
        #expect(span.charEnd == 19)
        // Multi-token reconstruction preserves the inter-token space.
        #expect(span.text == "(415) 555-0184")
        #expect(span.score >= Float(floor) && span.score <= 1.0)

        let redaction = PIISpanRedactor.apply(spans: spans, to: text)
        #expect(redaction.redacted == "Call [REDACTED:PII_PRIVATE_PHONE] before the window closes")
        #expect(redaction.patterns == ["PII_PRIVATE_PHONE"])
        #expect(!redaction.redacted.contains("415"))
        #expect(!redaction.redacted.contains("555-0184"))
    }

    // MARK: 3. SSN

    @Test("real SSN fixture: S-account_number span (the 8-way space's SSN home) detected and redacted as PII_ACCOUNT_NUMBER")
    func ssnFixtureDetectsAndRedacts() throws {
        guard Self.offline else { return }  // real-model arm lands with T.2b — no download from a test run

        // The 8-category tag space has no dedicated SSN class — government
        // ID shapes route to `account_number` per the model card mapping.
        let ssn = "078-05-1120"
        let text = "SSN \(ssn) is on file for the claim"
        let spans = try rulePath(tags: [ssn: .S(.accountNumber)])
            .detectSpans(text, floor)

        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.category == .accountNumber)
        #expect(span.charStart == 4)
        #expect(span.charEnd == 4 + ssn.count)
        #expect(span.text == ssn)
        #expect(span.score >= Float(floor) && span.score <= 1.0)

        let redaction = PIISpanRedactor.apply(spans: spans, to: text)
        #expect(redaction.redacted == "SSN [REDACTED:PII_ACCOUNT_NUMBER] is on file for the claim")
        #expect(redaction.patterns == ["PII_ACCOUNT_NUMBER"])
        #expect(!redaction.redacted.contains(ssn))
    }

    // MARK: 4. Name

    @Test("real multi-token name fixture: B/I/I/E-private_person collapses to one span and redacts as PII_PRIVATE_PERSON")
    func nameFixtureCollapsesAndRedacts() throws {
        guard Self.offline else { return }  // real-model arm lands with T.2b — no download from a test run

        let text = "Please loop in Maria del Carmen Rojas about the rollout"
        let spans = try rulePath(tags: [
            "Maria":  .B(.privatePerson),
            "del":    .I(.privatePerson),
            "Carmen": .I(.privatePerson),
            "Rojas":  .E(.privatePerson),
        ]).detectSpans(text, floor)

        #expect(spans.count == 1)
        let span = try #require(spans.first)
        #expect(span.category == .privatePerson)
        #expect(span.charStart == 15)
        #expect(span.charEnd == 37)
        // Four tokens collapse into ONE span with whitespace-shape-preserving
        // text reconstruction — the boundary contract the Viterbi table pins.
        #expect(span.text == "Maria del Carmen Rojas")
        #expect(span.score >= Float(floor) && span.score <= 1.0)

        let redaction = PIISpanRedactor.apply(spans: spans, to: text)
        #expect(redaction.redacted == "Please loop in [REDACTED:PII_PRIVATE_PERSON] about the rollout")
        #expect(redaction.patterns == ["PII_PRIVATE_PERSON"])
        // No partial leak: neither the head nor the tail token survives.
        #expect(!redaction.redacted.contains("Maria"))
        #expect(!redaction.redacted.contains("Rojas"))
    }
}

// MARK: - Test-local atomic

/// File-scope to avoid colliding with `Atomic` defined in
/// `ModelManagerInstallTests.swift` (also fileprivate, no leak).
fileprivate final class TestAtomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ initial: Int) { self.value = initial }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
