import Foundation

/// Tracks per-command metrics for a senkani session.
/// Writes metrics to a JSON file for cross-session comparison.
public final class SessionMetrics: @unchecked Sendable {
    private var commands: [CommandMetric] = []
    private let lock = NSLock()
    public let mode: String
    public let metricsPath: String?

    public init(mode: String, metricsPath: String? = nil) {
        self.mode = mode
        self.metricsPath = metricsPath
    }

    public struct CommandMetric: Codable, Sendable {
        public let command: String
        public let rawBytes: Int
        public let filteredBytes: Int
        public let savedBytes: Int
        public let savingsPercent: Double
        public let secretsFound: Int
        public let timestamp: Date
        public let featureBreakdown: [FeatureContribution]?
    }

    /// Record a command's metrics.
    public func record(_ result: PipelineResult) {
        let metric = CommandMetric(
            command: result.command,
            rawBytes: result.rawBytes,
            filteredBytes: result.filteredBytes,
            savedBytes: result.savedBytes,
            savingsPercent: result.savingsPercent,
            secretsFound: result.secretsFound.count,
            timestamp: Date(),
            featureBreakdown: result.featureBreakdown.isEmpty ? nil : result.featureBreakdown
        )
        lock.lock()
        commands.append(metric)
        lock.unlock()

        // Append to metrics file if configured
        if let path = metricsPath {
            appendToFile(metric, path: path)
        }
    }

    /// Get the session summary.
    public func summary() -> SessionSummary {
        lock.lock()
        let snapshot = commands
        lock.unlock()

        let totalRaw = snapshot.reduce(0) { $0 + $1.rawBytes }
        let totalFiltered = snapshot.reduce(0) { $0 + $1.filteredBytes }
        let totalSecrets = snapshot.reduce(0) { $0 + $1.secretsFound }

        // Top savings by command base name
        var byCommand: [String: (raw: Int, filtered: Int)] = [:]
        for cmd in snapshot {
            let base = cmd.command.split(separator: " ").first.map(String.init) ?? cmd.command
            let existing = byCommand[base, default: (0, 0)]
            byCommand[base] = (existing.raw + cmd.rawBytes, existing.filtered + cmd.filteredBytes)
        }

        let topSavings = byCommand
            .map { (command: $0.key, raw: $0.value.raw, filtered: $0.value.filtered) }
            .filter { $0.raw > 0 }
            .sorted { a, b in
                let aPct = Double(a.raw - a.filtered) / Double(a.raw)
                let bPct = Double(b.raw - b.filtered) / Double(b.raw)
                return aPct > bPct
            }
            .prefix(5)
            .map { TopSaving(command: $0.command, rawBytes: $0.raw, filteredBytes: $0.filtered) }

        return SessionSummary(
            mode: mode,
            commandCount: snapshot.count,
            totalRawBytes: totalRaw,
            totalFilteredBytes: totalFiltered,
            totalSecretsCaught: totalSecrets,
            topSavings: topSavings
        )
    }

    /// Format summary as a human-readable string.
    public func formattedSummary() -> String {
        let s = summary()
        var lines: [String] = []
        lines.append("")
        lines.append("Session complete.")
        lines.append("  Mode: \(s.mode)")
        lines.append("  Commands intercepted: \(s.commandCount)")
        lines.append("  Raw output:    \(formatBytes(s.totalRawBytes))")
        lines.append("  Filtered:      \(formatBytes(s.totalFilteredBytes)) (\(String(format: "%.0f", s.savingsPercent))% reduction)")
        if !s.topSavings.isEmpty {
            lines.append("")
            lines.append("  Top savings:")
            for top in s.topSavings {
                let pct = top.rawBytes > 0
                    ? String(format: "%.0f", Double(top.rawBytes - top.filteredBytes) / Double(top.rawBytes) * 100)
                    : "0"
                lines.append("    \(top.command.padding(toLength: 16, withPad: " ", startingAt: 0))→ \(pct)%")
            }
        }
        if s.totalSecretsCaught > 0 {
            lines.append("")
            lines.append("  Secrets caught: \(s.totalSecretsCaught)")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 {
            return String(format: "%.1fM bytes", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1fK bytes", Double(bytes) / 1_000)
        }
        return "\(bytes) bytes"
    }

    private func appendToFile(_ metric: CommandMetric, path: String) {
        guard let data = try? JSONEncoder().encode(metric),
              let json = String(data: data, encoding: .utf8) else { return }
        let line = json + "\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }
}

public struct SessionSummary: Sendable {
    public let mode: String
    public let commandCount: Int
    public let totalRawBytes: Int
    public let totalFilteredBytes: Int
    public let totalSecretsCaught: Int
    public let topSavings: [TopSaving]

    public var savedBytes: Int { totalRawBytes - totalFilteredBytes }
    public var savingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(savedBytes) / Double(totalRawBytes) * 100
    }
}

public struct TopSaving: Sendable {
    public let command: String
    public let rawBytes: Int
    public let filteredBytes: Int
}
