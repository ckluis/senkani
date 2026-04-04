import Testing
import Foundation
@testable import Core
@testable import Filter

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
