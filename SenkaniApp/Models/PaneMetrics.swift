import Foundation
import Core

/// A time-series data point for charts.
struct MetricsDataPoint: Identifiable {
    let id = UUID()
    let timestamp: Date
    let cumulativeSavedBytes: Int
    let cumulativeRawBytes: Int
}

/// Per-command breakdown entry for bar charts.
struct CommandBreakdownEntry: Identifiable {
    let id = UUID()
    let command: String
    var rawBytes: Int
    var filteredBytes: Int
    var savedBytes: Int { rawBytes - filteredBytes }
}

/// Live metrics for a single pane.
///
/// Byte values are maintained for feature breakdown views and per-pane analytics.
/// Project-level token stats are handled by MetricsStore (reads from DB).
@Observable
final class PaneMetrics {
    // MARK: - Token values (per-pane, accumulated from record() calls)

    var totalInputTokens: Int = 0
    var totalOutputTokens: Int = 0
    var totalSavedTokens: Int = 0
    var commandCount: Int = 0

    // MARK: - Byte-level tracking (for feature breakdown, charts)

    var totalRawBytes: Int = 0
    var totalFilteredBytes: Int = 0
    var secretsCaught: Int = 0
    var perFeatureSaved: [String: Int] = [:]

    /// Per-feature command count (how many commands each feature handled)
    var perFeatureCommandCount: [String: Int] = [:]

    /// Secret pattern breakdown (pattern name → count)
    var secretPatterns: [String: Int] = [:]

    /// Per-command family breakdown (git, cat, grep, etc.)
    var commandBreakdown: [String: (raw: Int, filtered: Int)] = [:]

    /// Per-feature per-command breakdown: feature → [(command, savedBytes)]
    var perFeatureCommands: [String: [String: Int]] = [:]

    /// Cache hit/miss tracking
    var cacheHits: Int = 0
    var cacheMisses: Int = 0

    /// Time-series data for line/area charts
    var timeSeries: [MetricsDataPoint] = []

    /// Per-feature cumulative time-series for sparklines in the detail drawer.
    /// Capped at maxTimeSeriesPoints entries per feature to prevent unbounded growth.
    private(set) var perFeatureTimeSeries: [String: [MetricsDataPoint]] = [:]
    private let maxTimeSeriesPoints = 1000

    var savedBytes: Int { totalRawBytes - totalFilteredBytes }
    var savingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(totalRawBytes) * 100
    }

    /// Estimated cost saved (dollars) using active model pricing
    var formattedCostSaved: String {
        let cost = Double(totalSavedTokens) / 1_000_000.0 * pricing.inputPerMillion
        if cost < 0.001 { return "$0.000" }
        if cost < 1.0 { return String(format: "$%.3f", cost) }
        if cost < 100.0 { return String(format: "$%.2f", cost) }
        return String(format: "$%.0f", cost)
    }

    // MARK: - Per-row cost & savings (for TokenCounterFooter)

    /// Active model pricing rates ($/M tokens)
    private var pricing: ModelPricing { ModelPricing.active }

    /// Input tokens saved = totalSavedTokens (senkani compresses input)
    var inputTokensSaved: Int { totalSavedTokens }

    /// Total input cost (input tokens at input rate)
    var inputCostTotal: Double {
        Double(totalInputTokens) / 1_000_000.0 * pricing.inputPerMillion
    }

    /// Input cost saved (saved tokens at input rate)
    var inputCostSaved: Double {
        Double(inputTokensSaved) / 1_000_000.0 * pricing.inputPerMillion
    }

    /// Output tokens saved (terse mode — not yet tracked)
    var outputTokensSaved: Int { 0 }

    /// Total output cost (output tokens at output rate)
    var outputCostTotal: Double {
        Double(totalOutputTokens) / 1_000_000.0 * pricing.outputPerMillion
    }

    /// Output cost saved
    var outputCostSaved: Double {
        Double(outputTokensSaved) / 1_000_000.0 * pricing.outputPerMillion
    }

    /// Total cost (input + output)
    var totalCost: Double { inputCostTotal + outputCostTotal }

    /// Total cost saved (input + output)
    var totalCostSaved: Double { inputCostSaved + outputCostSaved }

    var formattedSavings: String {
        if savedBytes >= 1_000_000 { return String(format: "%.1fM", Double(savedBytes) / 1_000_000) }
        if savedBytes >= 1_000 { return String(format: "%.1fK", Double(savedBytes) / 1_000) }
        return "\(savedBytes)B"
    }

    var formattedPercent: String {
        String(format: "%.0f%%", savingsPercent)
    }

    /// Sorted breakdown entries for charts.
    var breakdownEntries: [CommandBreakdownEntry] {
        commandBreakdown.map { key, value in
            CommandBreakdownEntry(command: key, rawBytes: value.raw, filteredBytes: value.filtered)
        }
        .sorted { $0.savedBytes > $1.savedBytes }
    }

    /// Cache hit rate (0.0 - 1.0)
    var cacheHitRate: Double {
        let total = cacheHits + cacheMisses
        guard total > 0 else { return 0 }
        return Double(cacheHits) / Double(total)
    }

    /// Top commands for a given feature, sorted by bytes saved (descending).
    func topCommands(for feature: String, limit: Int = 5) -> [(command: String, saved: Int)] {
        guard let cmdMap = perFeatureCommands[feature] else { return [] }
        return cmdMap.map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0 }
    }

    func record(rawBytes: Int, filteredBytes: Int, secrets: Int, feature: String?, command: String? = nil, secretPatternNames: [String] = []) {
        totalRawBytes += rawBytes
        totalFilteredBytes += filteredBytes
        commandCount += 1
        secretsCaught += secrets
        print("🟠 PANE METRICS: thread=\(Thread.isMainThread ? "MAIN ✓" : "BACKGROUND ⚠️") savedBytes=\(savedBytes) commandCount=\(commandCount)")

        // Track secret pattern names
        for pattern in secretPatternNames {
            secretPatterns[pattern, default: 0] += 1
        }

        let saved = rawBytes - filteredBytes
        if let f = feature {
            perFeatureSaved[f, default: 0] += saved
            perFeatureCommandCount[f, default: 0] += 1

            // Per-feature per-command tracking
            if let cmd = command {
                let base = cmd.split(separator: " ").first.map(String.init) ?? cmd
                var cmdMap = perFeatureCommands[f, default: [:]]
                cmdMap[base, default: 0] += saved
                perFeatureCommands[f] = cmdMap
            }

            // Per-feature time-series for sparkline (ring buffer, capped at maxTimeSeriesPoints)
            let prevSaved = perFeatureTimeSeries[f]?.last?.cumulativeSavedBytes ?? 0
            let prevRaw   = perFeatureTimeSeries[f]?.last?.cumulativeRawBytes   ?? 0
            let point = MetricsDataPoint(
                timestamp: Date(),
                cumulativeSavedBytes: prevSaved + saved,
                cumulativeRawBytes:   prevRaw   + rawBytes
            )
            var series = perFeatureTimeSeries[f] ?? []
            series.append(point)
            if series.count > maxTimeSeriesPoints { series.removeFirst() }
            perFeatureTimeSeries[f] = series
        }

        // Track per-command breakdown
        if let cmd = command {
            let base = cmd.split(separator: " ").first.map(String.init) ?? cmd
            let existing = commandBreakdown[base, default: (raw: 0, filtered: 0)]
            commandBreakdown[base] = (raw: existing.raw + rawBytes, filtered: existing.filtered + filteredBytes)
        }

        // Append time-series point
        timeSeries.append(MetricsDataPoint(
            timestamp: Date(),
            cumulativeSavedBytes: savedBytes,
            cumulativeRawBytes: totalRawBytes
        ))
    }

    /// Record a cache hit or miss.
    func recordCacheEvent(hit: Bool) {
        if hit { cacheHits += 1 } else { cacheMisses += 1 }
    }

    func reset() {
        totalInputTokens = 0
        totalOutputTokens = 0
        totalSavedTokens = 0
        commandCount = 0
        totalRawBytes = 0
        totalFilteredBytes = 0
        secretsCaught = 0
        perFeatureSaved = [:]
        perFeatureCommandCount = [:]
        secretPatterns = [:]
        commandBreakdown = [:]
        perFeatureCommands = [:]
        cacheHits = 0
        cacheMisses = 0
        timeSeries = []
        perFeatureTimeSeries = [:]
    }
}
