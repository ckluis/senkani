import Foundation

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

/// Live metrics for a single pane, updated by MetricsWatcher.
@Observable
final class PaneMetrics {
    var totalRawBytes: Int = 0
    var totalFilteredBytes: Int = 0
    var commandCount: Int = 0
    var secretsCaught: Int = 0
    var perFeatureSaved: [String: Int] = [:]

    /// Per-command family breakdown (git, cat, grep, etc.)
    var commandBreakdown: [String: (raw: Int, filtered: Int)] = [:]

    /// Time-series data for line/area charts
    var timeSeries: [MetricsDataPoint] = []

    var savedBytes: Int { totalRawBytes - totalFilteredBytes }
    var savingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(totalRawBytes) * 100
    }

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

    func record(rawBytes: Int, filteredBytes: Int, secrets: Int, feature: String?, command: String? = nil) {
        totalRawBytes += rawBytes
        totalFilteredBytes += filteredBytes
        commandCount += 1
        secretsCaught += secrets
        if let f = feature {
            perFeatureSaved[f, default: 0] += (rawBytes - filteredBytes)
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

    func reset() {
        totalRawBytes = 0
        totalFilteredBytes = 0
        commandCount = 0
        secretsCaught = 0
        perFeatureSaved = [:]
        commandBreakdown = [:]
        timeSeries = []
    }
}
