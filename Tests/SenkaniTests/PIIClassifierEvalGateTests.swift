import Testing
import Foundation
@testable import CLI
@testable import Core

/// Sendable counter for cross-closure call counts. The harness sink
/// closure is `@Sendable`, so captured mutable state needs ref-type
/// wrapping with explicit locking.
final class SendableRowCounter: @unchecked Sendable {
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

@Suite("PIIClassifier eval gate (T.2b-2) — F1 thresholds + buffer + harness + doctor extension", .serialized)
struct PIIClassifierEvalGateTests {

    // MARK: - Test 1 — F1 threshold logic

    @Test("f1Status bands honor 0.95 / 0.90 boundaries (clean / warn / abort)")
    func f1StatusBands() {
        // Clean band: F1 ≥ 0.95.
        #expect(PIIClassifierEvalGate.f1Status(0.96) == .clean)
        #expect(PIIClassifierEvalGate.f1Status(0.95) == .clean,
                "0.95 is the clean floor — inclusive")
        #expect(PIIClassifierEvalGate.f1Status(1.00) == .clean)

        // Warn band: 0.90 ≤ F1 < 0.95.
        #expect(PIIClassifierEvalGate.f1Status(0.94) == .warn(0.94))
        #expect(PIIClassifierEvalGate.f1Status(0.92) == .warn(0.92))
        #expect(PIIClassifierEvalGate.f1Status(0.90) == .warn(0.90),
                "0.90 is the warn floor — inclusive")

        // Abort band: F1 < 0.90.
        #expect(PIIClassifierEvalGate.f1Status(0.88) == .abort(0.88))
        #expect(PIIClassifierEvalGate.f1Status(0.00) == .abort(0.00))

        // Warning-line formatter: nil for clean, populated for warn + abort.
        #expect(PIIClassifierEvalGate.changelogWarningLine(
            modelId: "pii-classifier-int8", status: .clean) == nil)
        let warnLine = PIIClassifierEvalGate.changelogWarningLine(
            modelId: "pii-classifier-int8", status: .warn(0.92))
        #expect(warnLine?.contains("MODEL_QUALITY_WARNING") == true)
        #expect(warnLine?.contains("pii-classifier-int8") == true)
        #expect(warnLine?.contains("0.920") == true)
        let abortLine = PIIClassifierEvalGate.changelogWarningLine(
            modelId: "pii-classifier-int8", status: .abort(0.88))
        #expect(abortLine?.contains("aborted") == true)
    }

    // MARK: - Test 2 — MLWarningBuffer round-trip

    @Test("MLWarningBuffer append/latest/all/clear round-trips at a custom path")
    func warningBufferRoundTrip() throws {
        let dir = NSTemporaryDirectory() + "ml-warn-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let buf = MLWarningBuffer(path: URL(fileURLWithPath: dir + "warnings.json"))

        // Empty buffer reads as no entries / nil latest.
        #expect(buf.all().isEmpty)
        #expect(buf.latest() == nil)

        // Append three entries in chronological order; latest returns
        // the highest-timestamp row.
        let now = Date()
        let e1 = MLWarningBuffer.Entry(
            timestamp: now.addingTimeInterval(-200),
            modelId: "pii-classifier-int8",
            f1: 0.93,
            message: "[MODEL_QUALITY_WARNING] pii-classifier-int8: F1 0.930 in warn band"
        )
        let e2 = MLWarningBuffer.Entry(
            timestamp: now.addingTimeInterval(-100),
            modelId: "pii-classifier-int8",
            f1: 0.91,
            message: "[MODEL_QUALITY_WARNING] pii-classifier-int8: F1 0.910 in warn band"
        )
        let e3 = MLWarningBuffer.Entry(
            timestamp: now,
            modelId: "pii-classifier-int8",
            f1: 0.92,
            message: "[MODEL_QUALITY_WARNING] pii-classifier-int8: F1 0.920 in warn band"
        )
        try buf.append(e1)
        try buf.append(e2)
        try buf.append(e3)

        #expect(buf.all().count == 3)
        let latest = buf.latest()
        #expect(latest != nil)
        #expect(latest?.f1 == 0.92)
        // ISO8601 round-trip drops sub-second precision; compare with tolerance.
        if let ts = latest?.timestamp {
            #expect(abs(ts.timeIntervalSince(now)) < 1.0)
        }

        // Clear drops the file; reads return empty / nil.
        try buf.clear()
        #expect(buf.all().isEmpty)
        #expect(buf.latest() == nil)
    }

    // MARK: - Test 3 — PIIClassifierEvalHarness conditional-skip + warn-band write

    @Test("Harness conditional-skip + cached-F1 warn band drives sink + buffer write")
    func harnessConditionalSkipPlusWarnBandWrite() throws {
        let dir = NSTemporaryDirectory() + "ml-warn-test-\(UUID().uuidString)/"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let buf = MLWarningBuffer(path: URL(fileURLWithPath: dir + "warnings.json"))

        // Conditional-skip path 1 — dataset not pulled.
        let skipped1 = PIIClassifierEvalHarness(
            datasetStatusProvider: { .available },
            classifierStatusProvider: { .verified },
            layer3: Layer3Inference { _ in [] },
            resultsSink: { _, _, _, _, _ in
                Issue.record("resultsSink must NOT fire when dataset not pulled")
            },
            warningBuffer: buf
        ).runOrSkip()
        if case .skipped(let reason) = skipped1 {
            #expect(reason.contains("dataset not pulled"))
        } else {
            Issue.record("expected .skipped(dataset not pulled), got \(skipped1)")
        }

        // Conditional-skip path 2 — both verified, but inference seam
        // throws BackendNotReadyError (T.2a-followup not wired).
        let throwingSeam = Layer3Inference { _ in
            throw PIIClassifierAdapter.BackendNotReadyError(stage: "inference")
        }
        let skipped2 = PIIClassifierEvalHarness(
            datasetStatusProvider: { .verified },
            classifierStatusProvider: { .verified },
            layer3: throwingSeam,
            resultsSink: { _, _, _, _, _ in
                Issue.record("resultsSink must NOT fire when backend not ready")
            },
            warningBuffer: buf
        ).runOrSkip()
        if case .skipped(let reason) = skipped2 {
            #expect(reason.contains("backend not ready"))
        } else {
            Issue.record("expected .skipped(backend not ready), got \(skipped2)")
        }

        // Cached-F1 path — exercises gate + sink + warning buffer.
        let sunkRowCount = SendableRowCounter()
        let harness = PIIClassifierEvalHarness(
            datasetStatusProvider: { .verified },
            classifierStatusProvider: { .verified },
            layer3: Layer3Inference { _ in [] },
            resultsSink: { _, _, _, _, _ in
                sunkRowCount.increment()
            },
            warningBuffer: buf
        )

        // Clean band — no warning buffered.
        let clean = harness.runWithCachedF1(
            fixtureId: "smoke-001", precision: 0.97, recall: 0.95, f1: 0.96, durationMs: 100)
        #expect(clean == .completed(f1: 0.96, status: .clean))
        #expect(sunkRowCount.value == 1)
        #expect(buf.all().isEmpty, "clean band must NOT buffer a warning")

        // Warn band — sink + buffer entry.
        let warn = harness.runWithCachedF1(
            fixtureId: "smoke-002", precision: 0.93, recall: 0.91, f1: 0.92, durationMs: 110)
        #expect(warn == .completed(f1: 0.92, status: .warn(0.92)))
        #expect(sunkRowCount.value == 2)
        let warnEntries = buf.all()
        #expect(warnEntries.count == 1)
        #expect(warnEntries[0].modelId == "pii-classifier-int8")
        #expect(warnEntries[0].f1 == 0.92)
        #expect(warnEntries[0].message.contains("MODEL_QUALITY_WARNING"))

        // Abort band — sink + buffer entry; harness reports .abort
        // so the eval test (in production) can #expect-fail off it.
        let abort = harness.runWithCachedF1(
            fixtureId: "smoke-003", precision: 0.85, recall: 0.91, f1: 0.88, durationMs: 120)
        #expect(abort == .completed(f1: 0.88, status: .abort(0.88)))
        #expect(sunkRowCount.value == 3)
        #expect(buf.all().count == 2, "abort band must also buffer a warning")
    }

    // MARK: - Test 4 — Doctor 3-line formatter

    @Test("Doctor Layer 3 formatter emits 1 line for non-verified states, 3 lines when .verified (T.2b-2 extension)")
    func doctorThreeLineFormatter() {
        // Non-verified: only the Layer 3 status line is emitted.
        let availableLines = Doctor.formatLayer3PIIClassifierLines(
            status: .available,
            smoke: { .backendNotReady },
            lastEval: nil
        )
        #expect(availableLines.count == 1)
        #expect(availableLines[0].1.contains("not pulled"))

        let brokenLines = Doctor.formatLayer3PIIClassifierLines(
            status: .broken,
            smoke: { .backendNotReady },
            lastError: "weight checksum mismatch"
        )
        #expect(brokenLines.count == 1)
        #expect(brokenLines[0].1.contains("verification failed"))

        // .verified state — three lines: Layer 3 + commit-sha + last-eval.
        // Branch A: backend-not-ready, no commit-sha, no eval.
        let verifiedSkippy = Doctor.formatLayer3PIIClassifierLines(
            status: .verified,
            smoke: { .backendNotReady },
            localCommitSha: nil,
            lastEval: nil
        )
        #expect(verifiedSkippy.count == 3)
        #expect(verifiedSkippy[0].1.contains("backend not ready"))
        #expect(verifiedSkippy[1].1.contains("@ unknown"))
        #expect(verifiedSkippy[2].1.contains("never run"))

        // Branch B: .verified + smoke success + commit + clean eval.
        let cleanEvalTs = Date(timeIntervalSince1970: 1_745_000_000)
        let verifiedClean = Doctor.formatLayer3PIIClassifierLines(
            status: .verified,
            smoke: { .success },
            localCommitSha: "abcdef0123456789",
            lastEval: (timestamp: cleanEvalTs, f1: 0.96)
        )
        #expect(verifiedClean.count == 3)
        #expect(verifiedClean[0].1.contains("available"))
        #expect(verifiedClean[1].1.contains("@ abcdef012345"),
                "commit sha is truncated to 12 chars")
        #expect(verifiedClean[2].1.contains("F1 0.960"))
        #expect(verifiedClean[2].1.contains("(clean)"))

        // Branch C: .verified + warn-band eval → eval line surfaces
        // .fail status so doctor exit code reflects the warning.
        let verifiedWarn = Doctor.formatLayer3PIIClassifierLines(
            status: .verified,
            smoke: { .success },
            localCommitSha: "deadbeefcafe1234",
            lastEval: (timestamp: cleanEvalTs, f1: 0.92)
        )
        #expect(verifiedWarn.count == 3)
        let (warnStatus, warnMsg) = verifiedWarn[2]
        #expect(warnStatus == .fail, "warn band surfaces as fail status so doctor exits non-zero")
        #expect(warnMsg.contains("F1 0.920"))
        #expect(warnMsg.contains("warn"))
    }
}
