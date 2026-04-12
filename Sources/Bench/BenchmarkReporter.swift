import Foundation

/// Formats a BenchmarkReport as human-readable terminal output.
public enum BenchmarkReporter {

    public static func textReport(_ report: BenchmarkReport) -> String {
        var lines: [String] = []

        lines.append("")
        lines.append("\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}")
        lines.append("  Senkani Token Savings Benchmark")
        lines.append("  \(formatDate(report.timestamp))")
        lines.append("\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}\u{2550}")
        lines.append("")

        // Per-task breakdown grouped by category
        lines.append("Task Results")
        let separator = String(repeating: "\u{2500}", count: 63)
        lines.append(separator)

        let byCategory = Dictionary(grouping: report.results, by: \.category)
        for category in byCategory.keys.sorted() {
            let categoryResults = byCategory[category] ?? []
            let byTask = Dictionary(grouping: categoryResults, by: \.taskId)

            for taskId in byTask.keys.sorted() {
                guard let taskResults = byTask[taskId] else { continue }
                lines.append("")
                lines.append("  \(category): \(taskId)")

                for result in taskResults.sorted(by: { $0.configName < $1.configName }) {
                    let name = result.configName.padding(toLength: 14, withPad: " ", startingAt: 0)
                    let saved = String(format: "%6.1f%%", result.savedPct)
                    let raw = formatBytes(result.rawBytes).padding(toLength: 8, withPad: " ", startingAt: 0)
                    let comp = formatBytes(result.compressedBytes).padding(toLength: 8, withPad: " ", startingAt: 0)
                    lines.append("    \(name) \(raw) \u{2192} \(comp)  \(saved)")
                }
            }
        }

        lines.append("")
        lines.append("Quality Gates")
        lines.append(separator)
        for gate in report.gates {
            let mark = gate.passed ? "\u{2713}" : "\u{2717}"
            let name = gate.name.padding(toLength: 28, withPad: " ", startingAt: 0)
            let actual = String(format: "%6.1f", gate.actual)
            let threshold = String(format: "%6.1f", gate.threshold)
            let unit = gate.category == "overall" && gate.name.contains("multiplier") ? "x" : "%"
            lines.append("  \(mark) \(name) \(actual)\(unit) (threshold: \(threshold)\(unit))")
        }

        lines.append("")
        lines.append(separator)
        let verdict = report.allGatesPassed ? "PASS" : "FAIL"
        let multiplier = String(format: "%.2fx", report.overallMultiplier)
        lines.append("  Overall: \(multiplier)  Verdict: \(verdict)")
        lines.append("  Duration: \(String(format: "%.0fms", report.durationMs))")
        let doubleLine = String(repeating: "\u{2550}", count: 63)
        lines.append(doubleLine)
        lines.append("")

        return lines.joined(separator: "\n")
    }

    public static func jsonReport(_ report: BenchmarkReport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(report)
    }

    // MARK: - Helpers

    private static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
