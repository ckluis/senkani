import Testing
import Foundation
@testable import Core
@testable import Filter

@Suite("FilterPipeline Integration")
struct FilterPipelineTests {
    @Test func filterDisabledPassesThrough() {
        let config = FeatureConfig(filter: false, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "git status", output: "\u{1B}[32mOn branch\u{1B}[0m")
        // ANSI should NOT be stripped when filter is off
        #expect(result.output.contains("\u{1B}"))
        #expect(result.featureBreakdown.isEmpty)
    }

    @Test func filterEnabledStripsANSI() {
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "git status", output: "\u{1B}[32mOn branch\u{1B}[0m")
        #expect(!result.output.contains("\u{1B}"))
        #expect(result.featureBreakdown.count == 1)
        #expect(result.featureBreakdown.first?.feature == .filter)
    }

    @Test func secretsEnabledRedacts() {
        let config = FeatureConfig(filter: false, secrets: true, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "cat .env", output: "KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
        #expect(result.output.contains("[REDACTED:"))
        #expect(!result.output.contains("sk-ant-"))
        #expect(result.secretsFound.count == 1)
    }

    @Test func bothFeaturesCompound() {
        let config = FeatureConfig(filter: true, secrets: true, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let input = "\u{1B}[32mKEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz\u{1B}[0m"
        let result = pipeline.process(command: "git status", output: input)
        // ANSI stripped AND secret redacted
        #expect(!result.output.contains("\u{1B}"))
        #expect(!result.output.contains("sk-ant-"))
        #expect(result.featureBreakdown.count == 2)
    }

    @Test func perFeatureByteTracking() {
        let config = FeatureConfig(filter: true, secrets: true, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let input = "\u{1B}[31mERROR\u{1B}[0m normal text\n\n\n\nmore text"
        let result = pipeline.process(command: "git status", output: input)

        let filterContrib = result.featureBreakdown.first { $0.feature == .filter }
        #expect(filterContrib != nil)
        #expect(filterContrib!.inputBytes > filterContrib!.outputBytes)  // Filter saved bytes
    }

    @Test func passthroughPreservesExitInfo() {
        let config = FeatureConfig(filter: false, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "unknown-cmd", output: "raw output here")
        #expect(result.output == "raw output here")
        #expect(result.rawBytes == result.filteredBytes)
        #expect(!result.wasFiltered)
    }
}

@Suite("SessionMetrics")
struct SessionMetricsTests {
    @Test func recordAndSummarize() {
        let metrics = SessionMetrics(mode: "filter")
        let config = FeatureConfig(filter: true, secrets: true, indexer: false)
        let pipeline = FilterPipeline(config: config)

        // Record a few commands
        let r1 = pipeline.process(command: "git status", output: "\u{1B}[32mOn branch main\u{1B}[0m\n\n\n\nclean")
        let r2 = pipeline.process(command: "npm install", output: String(repeating: "added pkg\n", count: 100))

        metrics.record(r1)
        metrics.record(r2)

        let summary = metrics.summary()
        #expect(summary.commandCount == 2)
        #expect(summary.totalRawBytes > 0)
        #expect(summary.totalFilteredBytes > 0)
    }

    @Test func formattedSummaryContainsKey() {
        let metrics = SessionMetrics(mode: "filter")
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "git status", output: "\u{1B}[32mtest\u{1B}[0m")
        metrics.record(result)

        let formatted = metrics.formattedSummary()
        #expect(formatted.contains("Session complete"))
        #expect(formatted.contains("filter"))
    }

    @Test func metricsFileWrite() throws {
        let path = "/tmp/senkani-test-metrics-\(UUID().uuidString).jsonl"
        let metrics = SessionMetrics(mode: "test", metricsPath: path)
        let config = FeatureConfig(filter: true, secrets: false, indexer: false)
        let pipeline = FilterPipeline(config: config)
        let result = pipeline.process(command: "git status", output: "test output")
        metrics.record(result)

        // Check file was written
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("git status"))
        #expect(content.contains("rawBytes"))

        try? FileManager.default.removeItem(atPath: path)
    }
}
