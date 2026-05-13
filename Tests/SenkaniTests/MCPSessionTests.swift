import Testing
import Foundation
@testable import Core
@testable import Filter
@testable import MCPServer

/// Tests for the metrics JSONL writing path used by MCPSession.recordMetrics.
/// MCPSession itself lives in MCPServer (which has heavy ML deps), so we test
/// the equivalent logic via SessionMetrics (Core) which uses the same JSONL format,
/// plus a direct JSONLMetricEntry encoding test.
@Suite("MCPSession Metrics JSONL")
struct MCPSessionMetricsTests {

    /// Test that recordMetrics with a metricsFilePath writes JSONL to the file.
    @Test func metricsFileWritesJSONL() throws {
        let path = "/tmp/senkani-mcpsession-test-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metrics = SessionMetrics(mode: "test", metricsPath: path)
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)

        let result1 = pipeline.process(command: "echo hello", output: "hello")
        let result2 = pipeline.process(command: "git status", output: "\u{1B}[32mOn branch main\u{1B}[0m\n\n\n\nclean")
        metrics.record(result1)
        metrics.record(result2)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2, "Expected 2 JSONL lines, got \(lines.count)")
    }

    /// Test that each JSONL line has the correct fields matching MCPSession.JSONLMetricEntry.
    @Test func jsonlLineHasCorrectFields() throws {
        let path = "/tmp/senkani-mcpsession-fields-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metrics = SessionMetrics(mode: "test", metricsPath: path)
        let config = FeatureConfig(filter: true, secrets: true, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "git log", output: String(repeating: "commit abc123\n", count: 100))
        metrics.record(result)

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let line = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // Parse as JSON dictionary
        let data = line.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        // Required fields (same as MCPSession.JSONLMetricEntry)
        #expect(json["command"] is String, "Missing or wrong type: command")
        #expect(json["rawBytes"] is Int, "Missing or wrong type: rawBytes")
        #expect(json["filteredBytes"] is Int, "Missing or wrong type: filteredBytes")
        #expect(json["savedBytes"] is Int, "Missing or wrong type: savedBytes")
        #expect(json["savingsPercent"] is Double, "Missing or wrong type: savingsPercent")
        #expect(json["secretsFound"] is Int, "Missing or wrong type: secretsFound")
        #expect(json["timestamp"] is Double, "Missing or wrong type: timestamp")

        // Invariant: rawBytes >= filteredBytes
        let rawBytes = json["rawBytes"] as! Int
        let filteredBytes = json["filteredBytes"] as! Int
        #expect(rawBytes >= filteredBytes, "rawBytes (\(rawBytes)) should be >= filteredBytes (\(filteredBytes))")

        // savedBytes == rawBytes - filteredBytes
        let savedBytes = json["savedBytes"] as! Int
        #expect(savedBytes == rawBytes - filteredBytes)
    }

    /// Test that recordMetrics without metricsFilePath doesn't crash (nil path).
    @Test func noMetricsPathDoesNotCrash() {
        let metrics = SessionMetrics(mode: "test", metricsPath: nil)
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "echo test", output: "test")
        // This should not crash — just no file written
        metrics.record(result)
        let summary = metrics.summary()
        #expect(summary.commandCount == 1)
    }

    /// Test that multiple records append (not overwrite) to the JSONL file.
    @Test func multipleRecordsAppend() throws {
        let path = "/tmp/senkani-mcpsession-append-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let metrics = SessionMetrics(mode: "test", metricsPath: path)
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)

        for i in 0..<5 {
            let result = pipeline.process(command: "cmd\(i)", output: String(repeating: "x", count: (i + 1) * 100))
            metrics.record(result)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 5, "Expected 5 JSONL lines, got \(lines.count)")

        // Each line should be independently parseable JSON
        for (i, line) in lines.enumerated() {
            let data = line.data(using: .utf8)!
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(json != nil, "Line \(i) is not valid JSON")
        }
    }
}

/// Compression-delta diagnostics on `MCPSession.recordMetrics` —
/// savings-pipeline-two-part-instrumentation-2026-05-12 Part B.
///
/// Pin: when compression hurts (`savedBytes <= 0`) the session emits a
/// `mcp.metrics.compression_negative` event ALWAYS. When
/// `SENKANI_SAVINGS_DEBUG=1` is set, the session also emits
/// `mcp.metrics.recorded` for every call (full per-call verbosity).
///
/// Why this matters: the parent walk found 3 mcp_tool rows with
/// `saved_tokens=0` on real Claude-session-driven Read tool calls,
/// blocking the `firstNonzeroSavings` onboarding milestone. The
/// instrumentation surfaces *why* the compression layer underperforms
/// on those call shapes (compressed body larger than raw, encoding
/// overhead, etc.) without re-running the manual walk.
///
/// `.loggerSinkGate` is required because `Logger._setTestSink` is a
/// process-global storage slot.
@Suite("MCPSession recordMetrics diagnostics", .serialized, .loggerSinkGate)
struct MCPSessionMetricsDiagnosticsTests {

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [(String, [String: LogValue])] = []
        func record(_ event: String, _ fields: [String: LogValue]) {
            lock.lock(); defer { lock.unlock() }
            _events.append((event, fields))
        }
        var events: [(String, [String: LogValue])] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }
    }

    private func intField(_ fields: [String: LogValue], _ key: String) -> Int? {
        guard let v = fields[key] else { return nil }
        if case .int(let i) = v { return i }
        return nil
    }

    private func stringField(_ fields: [String: LogValue], _ key: String) -> String? {
        guard let v = fields[key] else { return nil }
        if case .string(let s) = v { return s }
        return nil
    }

    @Test func negativeCompressionDeltaEmitsDiagnosticEvent() async {
        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        // Compression overhead on a short payload: compressed > raw.
        await session.recordMetrics(rawBytes: 100, compressedBytes: 150, feature: "filter", command: "echo")

        let negative = sink.events.filter { $0.0 == "mcp.metrics.compression_negative" }
        #expect(negative.count == 1, "Expected exactly one compression_negative event; got \(sink.events.map(\.0))")
        let fields = negative[0].1
        #expect(intField(fields, "raw_bytes") == 100)
        #expect(intField(fields, "compressed_bytes") == 150)
        #expect(intField(fields, "saved_bytes") == -50)
        #expect(stringField(fields, "tool_name") == "filter")
        #expect(stringField(fields, "feature") == "filter")
        #expect(stringField(fields, "command") == "echo")
    }

    @Test func positiveCompressionDeltaSuppressesDiagnosticEvent() async {
        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: "filter")

        let negative = sink.events.filter { $0.0 == "mcp.metrics.compression_negative" }
        #expect(negative.isEmpty, "Positive compression delta must not fire compression_negative")
    }

    @Test func savingsDebugEnvOptInEmitsPerCallVerbose() async {
        // Force the env-var cache to a known TRUE state via the test-only reset
        // + setenv. Restore afterwards so peer suites read the actual env.
        let prior = ProcessInfo.processInfo.environment["SENKANI_SAVINGS_DEBUG"]
        setenv("SENKANI_SAVINGS_DEBUG", "1", 1)
        MCPSession._resetSavingsDebugCacheForTesting()
        defer {
            if let prior {
                setenv("SENKANI_SAVINGS_DEBUG", prior, 1)
            } else {
                unsetenv("SENKANI_SAVINGS_DEBUG")
            }
            MCPSession._resetSavingsDebugCacheForTesting()
        }

        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: "filter")

        let recorded = sink.events.filter { $0.0 == "mcp.metrics.recorded" }
        #expect(recorded.count == 1, "SENKANI_SAVINGS_DEBUG=1 must emit one mcp.metrics.recorded per call")
        let fields = recorded[0].1
        #expect(intField(fields, "raw_bytes") == 1000)
        #expect(intField(fields, "compressed_bytes") == 200)
        #expect(intField(fields, "saved_bytes") == 800)
        #expect(stringField(fields, "tool_name") == "filter")
    }

    @Test func savingsDebugDisabledByDefault() async {
        unsetenv("SENKANI_SAVINGS_DEBUG")
        MCPSession._resetSavingsDebugCacheForTesting()
        defer { MCPSession._resetSavingsDebugCacheForTesting() }

        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: "filter")

        let recorded = sink.events.filter { $0.0 == "mcp.metrics.recorded" }
        #expect(recorded.isEmpty, "mcp.metrics.recorded must not fire when SENKANI_SAVINGS_DEBUG is unset")
    }
}
