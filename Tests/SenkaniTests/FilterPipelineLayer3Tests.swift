import Testing
import Foundation
import SQLite3
@testable import Core

@Suite("FilterPipeline Layer 3 (T.2b-1) — PIIClassifier wiring + audit chain", .serialized)
struct FilterPipelineLayer3Tests {

    // MARK: - Test 1 — Active path

    @Test("Layer 3 active path merges classifier spans into the redaction list alongside regex matches")
    func activePathMergesSpansWithRegex() {
        Layer3GateState.shared._resetForTests()
        let inputText = """
            Harry Potter visited Hogwarts.
            secret_key=sk-ant-api03-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
            """
        let pipeline = FilterPipeline(
            config: FeatureConfig(filter: false, secrets: true, terse: false, injectionGuard: false),
            layer3: Layer3Inference { text in
                // Inject a "Harry Potter" contextual-PII span at the
                // exact character offset where it appears in the
                // post-regex/entropy-redacted text. The redactor uses
                // char offsets into whatever currentOutput looks like
                // when Layer 3 fires.
                guard let range = text.range(of: "Harry Potter") else { return [] }
                let charStart = text.distance(from: text.startIndex, to: range.lowerBound)
                let charEnd = text.distance(from: text.startIndex, to: range.upperBound)
                return [PIISpan(
                    category: .privatePerson,
                    score: 0.97,
                    charStart: charStart,
                    charEnd: charEnd,
                    text: "Harry Potter"
                )]
            },
            layer3StatusProvider: { .verified }
        )
        let result = pipeline.process(command: "cat letter.txt", output: inputText)

        // Layer 1 (regex) catches the Anthropic key.
        #expect(result.secretsFound.contains("ANTHROPIC_KEY") ||
                result.secretsFound.contains(where: { $0.contains("ANTHROPIC") }))
        // Layer 3 catches Harry Potter as a private_person and the
        // redactor emits a PII_PRIVATE_PERSON pattern.
        #expect(result.secretsFound.contains("PII_PRIVATE_PERSON"))
        // The output text no longer contains "Harry Potter".
        #expect(!result.output.contains("Harry Potter"))
        // Layer 1's redaction marker is still present.
        #expect(result.output.contains("REDACTED"))
    }

    // MARK: - Test 2 — Inactive (not-pulled) path with per-process latch

    @Test("Layer 3 inactive path: status .available no-ops, regex+entropy still redact, latch fires .notPulled once per process")
    func inactivePathHoldsLatch() {
        Layer3GateState.shared._resetForTests()
        let mockLayer3 = Layer3Inference { _ in
            Issue.record("layer3 inference must NOT be called when status != .verified")
            return []
        }
        let pipeline = FilterPipeline(
            config: FeatureConfig(filter: false, secrets: true, terse: false, injectionGuard: false),
            layer3: mockLayer3,
            layer3StatusProvider: { .available }
        )
        let secretText = "AKIAIOSFODNN7EXAMPLE access key in plaintext"
        // First call — latch transitions, layer3 inference seam not
        // invoked, regex catches AWS key.
        let r1 = pipeline.process(command: "env", output: secretText)
        #expect(!r1.secretsFound.isEmpty, "regex Layer 1 must still redact")
        #expect(Layer3GateState.shared.shouldEmit(.notPulled) == false,
                "latch already burned by first call — shouldEmit returns false")
        // Second call — must NOT re-emit (latch holds).
        _ = pipeline.process(command: "env", output: secretText)
        #expect(Layer3GateState.shared.shouldEmit(.notPulled) == false,
                "latch stays burned across multiple calls — once-per-process semantics")
    }

    // MARK: - Test 3 — Backend-not-ready path

    /// Sendable counter for the backend-not-ready test seam — the
    /// inference closure is `@Sendable`, so the captured mutable
    /// state must be wrapped in a thread-safe ref type.
    final class SendableCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Int = 0
        var value: Int {
            lock.lock(); defer { lock.unlock() }
            return _value
        }
        func increment() {
            lock.lock(); _value += 1; lock.unlock()
        }
    }

    @Test("Layer 3 backend-not-ready path: status .verified + adapter throws → graceful no-op + per-process latch")
    func backendNotReadyGracefulDegradation() {
        Layer3GateState.shared._resetForTests()
        let seamCallCount = SendableCounter()
        let throwingSeam = Layer3Inference { _ in
            seamCallCount.increment()
            throw PIIClassifierAdapter.BackendNotReadyError(stage: "inference")
        }
        let pipeline = FilterPipeline(
            config: FeatureConfig(filter: false, secrets: true, terse: false, injectionGuard: false),
            layer3: throwingSeam,
            layer3StatusProvider: { .verified }
        )
        let payload = "AKIAIOSFODNN7EXAMPLE plus assorted text"
        // First call — adapter throws, latch fires .backendNotReady,
        // regex+entropy still redact.
        let r1 = pipeline.process(command: "env", output: payload)
        #expect(seamCallCount.value == 1, "adapter forward IS called when status is .verified")
        #expect(!r1.secretsFound.isEmpty, "regex Layer 1 must still redact")
        // Second call — latch holds (no re-emit), but adapter still
        // attempted (production path tries every call; the only thing
        // gated by the latch is the log line).
        _ = pipeline.process(command: "env", output: payload)
        #expect(seamCallCount.value == 2, "adapter forward is attempted on every call; the latch only gates the log")
        #expect(Layer3GateState.shared.shouldEmit(.backendNotReady) == false,
                "backendNotReady latch holds — log fires at most once per process boot")
    }

    // MARK: - Test 4 — T.5 chain integrity across 100 eval_results rows

    @Test("EvalResultsStore 100-row write storm — ChainVerifier.verifyEvalResults returns .ok")
    func chainIntegrityHundredRows() {
        let dir = NSTemporaryDirectory() + "senkani-eval-chain-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let db = SessionDatabase(path: dir + "senkani.db")

        for i in 0..<100 {
            let ok = db.recordEvalResult(
                modelId: "pii-classifier-int8",
                fixtureId: "fixture-\(i)",
                precision: 0.90 + Double(i) * 0.0001,
                recall: 0.92 + Double(i) * 0.0001,
                f1: 0.91 + Double(i) * 0.0001,
                durationMs: Int64(i * 5)
            )
            #expect(ok, "row \(i) must insert")
        }
        #expect(db.evalResultsCount() == 100)

        // Chain verifies clean across all 100 rows.
        let result = ChainVerifier.verifyEvalResults(db)
        switch result {
        case .ok: break
        default:
            Issue.record("expected .ok across 100 rows, got \(result)")
        }

        // verifyAll surfaces eval_results under the new key.
        let perTable = ChainVerifier.verifyAll(db)
        #expect(perTable["eval_results"] != nil, "verifyAll must include eval_results")

        // Tamper detection — rewrite one row's f1 directly. Verifier
        // must report .brokenAt on eval_results at that rowid.
        db.queue.sync {
            guard let raw = db.db else { return }
            sqlite3_exec(raw, "UPDATE eval_results SET f1 = 0.0 WHERE id = 42;", nil, nil, nil)
        }
        switch ChainVerifier.verifyEvalResults(db) {
        case .brokenAt(let table, let rowid, _, _):
            #expect(table == "eval_results")
            #expect(rowid == 42)
        default:
            Issue.record("expected .brokenAt(eval_results, 42) after tamper")
        }
    }
}
