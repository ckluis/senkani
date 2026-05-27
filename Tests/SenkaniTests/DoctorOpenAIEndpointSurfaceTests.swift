import Testing
import Foundation
@testable import CLI
@testable import Core

/// `phase-v13e-2-doctor-openai-check` (2026-05-27).
///
/// The `senkani doctor` OpenAI-endpoint check renders bind / port /
/// key-count / trailing-24h request count / 429-rate. The last two read
/// v13e-1's persisted request-log query API, so they survive a process
/// restart. These tests assert on the operator-facing surface directly
/// via the pure `Doctor.formatOpenAIEndpointLine` helper (mirror of
/// `DoctorAuditChainSurfaceTests`).
@Suite("DoctorOpenAIEndpointSurface (V.13e-2)")
struct DoctorOpenAIEndpointSurfaceTests {

    private static func tempDBPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-v13e-2-tests/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "doctor-openai-\(UUID().uuidString).db"
    }

    /// `doctor-openai-check-render` — the formatter renders all five named
    /// fields, is `.pass` (informational / non-blocking), formats the
    /// 429-rate as a human percentage, and surfaces only the key COUNT (no
    /// key material).
    @Test("doctor-openai-check-render — all five fields, percentage 429-rate, pass status")
    func rendersAllFiveFields() {
        let config = OpenAIEndpointConfig(bind: "127.0.0.1", port: 8470)
        let stats = OpenAIRequestLogStore.TrailingStats(
            count24h: 40, count429: 5, rate429: 0.125
        )
        let (status, line) = Doctor.formatOpenAIEndpointLine(
            config: config, keyCount: 3, stats: stats
        )

        // Informational / non-blocking — never trips the doctor exit code.
        guard case .pass = status else {
            Issue.record("expected .pass, got \(status): \(line)")
            return
        }

        // All five named fields present.
        #expect(line.contains("bind: 127.0.0.1"), "bind missing: \(line)")
        #expect(line.contains("port: 8470"), "port missing: \(line)")
        #expect(line.contains("keys: 3"), "key-count missing: \(line)")
        #expect(line.contains("requests (24h): 40"), "trailing-24h count missing: \(line)")
        // 429-rate rendered as a human percentage, not a raw 0.125 float.
        #expect(line.contains("429-rate: 12.5%"), "429-rate not a percentage: \(line)")
        #expect(!line.contains("0.125"), "raw rate float leaked into the line: \(line)")
    }

    /// Empty window: zero requests renders cleanly with no divide-by-zero
    /// artifact (0.0% rate).
    @Test("zero-request window renders 0 count and 0.0% rate")
    func rendersEmptyWindow() {
        let (_, line) = Doctor.formatOpenAIEndpointLine(
            config: .default,
            keyCount: 0,
            stats: OpenAIRequestLogStore.TrailingStats(count24h: 0, count429: 0, rate429: 0)
        )
        #expect(line.contains("requests (24h): 0"), "empty count missing: \(line)")
        #expect(line.contains("429-rate: 0.0%"), "empty rate missing: \(line)")
        #expect(line.contains("keys: 0"), "empty key-count missing: \(line)")
    }

    /// Acceptance bullet 2: requests-last-24h + 429-rate are read from
    /// v13e-1's persisted query API and survive a process restart. Write
    /// rows through one handle, reopen a fresh handle at the same path
    /// (cold cache — simulates a restart), pull the stats, and confirm the
    /// rendered doctor line reflects the PERSISTED values.
    @Test("trailing-24h count + 429-rate read cross-process render into the doctor line")
    func crossProcessStatsRenderIntoLine() {
        let path = Self.tempDBPath()
        let now = Date(timeIntervalSince1970: 1_900_000_000)

        // Handle 1 — write 4 in-window requests, 1 of which is a 429.
        do {
            let db1 = SessionDatabase(path: path)
            #expect(db1.recordOpenAIRequest(ts: now.addingTimeInterval(-60),
                surface: .chat, status: 200, keyLabel: "key-A"))
            #expect(db1.recordOpenAIRequest(ts: now.addingTimeInterval(-120),
                surface: .chatStream, status: 200, keyLabel: "key-A"))
            #expect(db1.recordOpenAIRequest(ts: now.addingTimeInterval(-3_600),
                surface: .embeddings, status: 429, keyLabel: "key-B"))
            #expect(db1.recordOpenAIRequest(ts: now.addingTimeInterval(-7_200),
                surface: .toolUse, status: 200, keyLabel: "key-A"))
            db1.close()
        }

        // Handle 2 — fresh process, cold cache, same path.
        let db2 = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db2, path: path) }
        let stats = db2.openAIRequestTrailing24hStats(now: now)

        let (_, line) = Doctor.formatOpenAIEndpointLine(
            config: .default, keyCount: 2, stats: stats
        )
        // 4 requests in window, 1 a 429 → 25.0%.
        #expect(line.contains("requests (24h): 4"), "persisted count not rendered: \(line)")
        #expect(line.contains("429-rate: 25.0%"), "persisted 429-rate not rendered: \(line)")
    }
}
