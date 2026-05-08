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
