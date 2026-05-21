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
///
/// **Parallel-mode flake mitigation (2026-05-21,
/// `test-flake-mcpsession-savings-debug-env-shared-sink-2026-05-13`):**
/// `SENKANI_SAVINGS_DEBUG=1` is process-global. When this suite sets it
/// + installs a Logger sink, peer suites that ALSO call
/// `MCPSession.recordMetrics` in parallel (e.g.
/// `MCPSessionActorIsolationTests.concurrentMutatorsConverge` with
/// `feature: "race"`, `MCPSessionRegistryIsolationTests` with
/// `feature: "registry-iso"`) start emitting `mcp.metrics.recorded`
/// events too — and those events land in THIS suite's installed sink
/// because the sink slot is process-global. `.loggerSinkGate`
/// serializes sink-using suites against each other (none of those
/// peers install sinks), but it does NOT block production
/// `Logger.log` writes from peer suites — that's the documented
/// contract limitation in `Tests/SenkaniTests/LoggerSinkGate.swift`.
/// The canonical mitigation (per LoggerSinkGate.swift's body comment)
/// is to filter `sink.events` by a unique field value, mirroring the
/// `pathField(...)` filter `LoggerRoutingTests` uses. We stamp each
/// test's `feature:` argument with a UUID-derived unique value and
/// filter `recorded` (or `negative`) events by `tool_name ==
/// uniqueFeature` before asserting counts. Peer events with
/// `tool_name == "race"` / `"registry-iso"` / `"test"` are excluded
/// by construction.
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

        // Unique feature name → filter peer-suite emissions out of our sink.
        // See suite docstring for the parallel-mode flake mechanism.
        let uniqueFeature = "savings-debug-negative-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        // Compression overhead on a short payload: compressed > raw.
        await session.recordMetrics(rawBytes: 100, compressedBytes: 150, feature: uniqueFeature, command: "echo")

        let negative = sink.events.filter { event, fields in
            event == "mcp.metrics.compression_negative"
                && stringField(fields, "tool_name") == uniqueFeature
        }
        #expect(negative.count == 1, "Expected exactly one compression_negative event for tool_name=\(uniqueFeature); got \(sink.events.map(\.0))")
        let fields = negative[0].1
        #expect(intField(fields, "raw_bytes") == 100)
        #expect(intField(fields, "compressed_bytes") == 150)
        #expect(intField(fields, "saved_bytes") == -50)
        #expect(stringField(fields, "tool_name") == uniqueFeature)
        #expect(stringField(fields, "feature") == uniqueFeature)
        #expect(stringField(fields, "command") == "echo")
    }

    @Test func positiveCompressionDeltaSuppressesDiagnosticEvent() async {
        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let uniqueFeature = "savings-debug-positive-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: uniqueFeature)

        let negative = sink.events.filter { event, fields in
            event == "mcp.metrics.compression_negative"
                && stringField(fields, "tool_name") == uniqueFeature
        }
        #expect(negative.isEmpty, "Positive compression delta must not fire compression_negative for tool_name=\(uniqueFeature)")
    }

    @Test func savingsDebugEnvOptInEmitsPerCallVerbose() async {
        // Force the env-var cache to a known TRUE state via the test-only reset
        // + setenv. Restore afterwards so peer suites read the actual env.
        //
        // While SENKANI_SAVINGS_DEBUG=1 is set process-globally, peer suites
        // calling MCPSession.recordMetrics also emit `mcp.metrics.recorded`
        // into whichever sink is currently installed (which is ours, until
        // our defer tears it down). We filter sink events by a UUID-derived
        // unique tool_name to exclude peers — see suite docstring.
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

        let uniqueFeature = "savings-debug-optin-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: uniqueFeature)

        let recorded = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == uniqueFeature
        }
        #expect(recorded.count == 1, "SENKANI_SAVINGS_DEBUG=1 must emit one mcp.metrics.recorded per call for tool_name=\(uniqueFeature); peer events with other tool_names are filtered out")
        let fields = recorded[0].1
        #expect(intField(fields, "raw_bytes") == 1000)
        #expect(intField(fields, "compressed_bytes") == 200)
        #expect(intField(fields, "saved_bytes") == 800)
        #expect(stringField(fields, "tool_name") == uniqueFeature)
    }

    @Test func savingsDebugDisabledByDefault() async {
        unsetenv("SENKANI_SAVINGS_DEBUG")
        MCPSession._resetSavingsDebugCacheForTesting()
        defer { MCPSession._resetSavingsDebugCacheForTesting() }

        let sink = Sink()
        Logger._setTestSink { event, fields in sink.record(event, fields) }
        defer { Logger._setTestSink(nil) }

        let uniqueFeature = "savings-debug-disabled-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: uniqueFeature)

        let recorded = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == uniqueFeature
        }
        #expect(recorded.isEmpty, "mcp.metrics.recorded must not fire for our tool_name when SENKANI_SAVINGS_DEBUG is unset (peer emissions with other tool_names are filtered out)")
    }

    // MARK: - Parallel-mode flake regression-watch
    // (test-flake-mcpsession-savings-debug-env-shared-sink-2026-05-13)
    //
    // Two tests written back-to-back demonstrate that the unique-tool_name
    // filter pattern isolates each sink-scope from cross-scope emissions
    // even when both scopes name the SAME event family. Each test's
    // `recorded` filter is keyed on its own UUID-derived unique feature
    // value, so the peer test's emission (which lands in the test's own
    // sink before defer-teardown) is excluded by construction.
    //
    // The two tests run sequentially under the suite's `.serialized` trait,
    // so the second test's sink installation happens AFTER the first's
    // tear-down. The filter convention is what guarantees correctness even
    // if a parallel peer (e.g. MCPSessionActorIsolationTests) is firing
    // recordMetrics calls during the window between install and tear-down.

    @Test func sinkIsolationFirstScopeSeesOnlyOwnEmission() async {
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

        let firstFeature = "isolation-first-\(UUID().uuidString)"
        let secondFeature = "isolation-second-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 1000, compressedBytes: 200, feature: firstFeature)

        let ownRecorded = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == firstFeature
        }
        let crossScope = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == secondFeature
        }
        #expect(ownRecorded.count == 1, "first scope must observe exactly its own emission")
        #expect(crossScope.isEmpty, "first scope must NOT observe second scope's emissions — UUID-stamped feature name precludes name collision")
    }

    @Test func sinkIsolationSecondScopeSeesOnlyOwnEmission() async {
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

        let firstFeature = "isolation-first-\(UUID().uuidString)"
        let secondFeature = "isolation-second-\(UUID().uuidString)"
        let session = MCPSession(projectRoot: "/tmp/savings-debug-\(UUID().uuidString)")
        await session.recordMetrics(rawBytes: 800, compressedBytes: 100, feature: secondFeature)

        let ownRecorded = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == secondFeature
        }
        let crossScope = sink.events.filter { event, fields in
            event == "mcp.metrics.recorded"
                && stringField(fields, "tool_name") == firstFeature
        }
        #expect(ownRecorded.count == 1, "second scope must observe exactly its own emission")
        #expect(crossScope.isEmpty, "second scope must NOT observe first scope's emissions — sink scope is fresh per test + UUID-stamped feature precludes name collision")
    }
}
