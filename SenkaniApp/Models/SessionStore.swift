import Foundation

/// Persisted summary of a past session.
struct SessionSummaryRecord: Codable, Identifiable {
    var id: String { filename }
    let filename: String
    let timestamp: Date
    let duration: TimeInterval
    let totalSaved: Int
    let totalRaw: Int
    let commandCount: Int
    let paneCount: Int

    var savingsPercent: Double {
        guard totalRaw > 0 else { return 0 }
        return Double(totalSaved) / Double(totalRaw) * 100
    }

    var formattedSavings: String {
        if totalSaved >= 1_000_000 { return String(format: "%.1fM", Double(totalSaved) / 1_000_000) }
        if totalSaved >= 1_000 { return String(format: "%.1fK", Double(totalSaved) / 1_000) }
        return "\(totalSaved)B"
    }

    var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    var estimatedCostSaved: Double {
        let tokens = Double(totalSaved) / 4.0
        return (tokens / 1_000_000) * 3.0
    }
}

/// Manages persistence and retrieval of session history.
@MainActor @Observable
final class SessionStore {
    static let shared = SessionStore()

    var pastSessions: [SessionSummaryRecord] = []

    private let sessionsDir: String

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        sessionsDir = appSupport.appendingPathComponent("Senkani/sessions").path
        try? FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        loadHistory()
    }

    // MARK: - Load

    func loadHistory() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var records: [SessionSummaryRecord] = []
        for file in files where file.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let record = try? decoder.decode(SessionSummaryRecord.self, from: data)
            else { continue }
            records.append(record)
        }

        pastSessions = records.sorted { $0.timestamp > $1.timestamp }
    }

    // MARK: - Save

    func saveSession(workspace: WorkspaceModel) {
        let now = Date()
        let duration = now.timeIntervalSince(workspace.sessionStart)
        let formatter = ISO8601DateFormatter()
        let filename = "session-\(formatter.string(from: now)).json"

        let record = SessionSummaryRecord(
            filename: filename,
            timestamp: now,
            duration: duration,
            totalSaved: workspace.totalSavedBytes,
            totalRaw: workspace.totalRawBytes,
            commandCount: workspace.panes.reduce(0) { $0 + $1.metrics.commandCount },
            paneCount: workspace.panes.count
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(record) else { return }
        let path = (sessionsDir as NSString).appendingPathComponent(filename)
        try? data.write(to: URL(fileURLWithPath: path))

        pastSessions.insert(record, at: 0)
    }

    // MARK: - Export

    /// Export current session metrics as JSON data.
    func exportJSON(workspace: WorkspaceModel) -> Data? {
        let now = Date()
        let duration = now.timeIntervalSince(workspace.sessionStart)

        struct ExportData: Codable {
            let timestamp: Date
            let duration: TimeInterval
            let totalRawBytes: Int
            let totalFilteredBytes: Int
            let totalSavedBytes: Int
            let savingsPercent: Double
            let commandCount: Int
            let paneCount: Int
            let estimatedCostSaved: Double
            let panes: [PaneExport]
        }

        struct PaneExport: Codable {
            let title: String
            let rawBytes: Int
            let filteredBytes: Int
            let savedBytes: Int
            let commandCount: Int
            let commandBreakdown: [String: BreakdownValues]
        }

        struct BreakdownValues: Codable {
            let raw: Int
            let filtered: Int
        }

        let paneExports = workspace.panes.map { pane in
            PaneExport(
                title: pane.title,
                rawBytes: pane.metrics.totalRawBytes,
                filteredBytes: pane.metrics.totalFilteredBytes,
                savedBytes: pane.metrics.savedBytes,
                commandCount: pane.metrics.commandCount,
                commandBreakdown: pane.metrics.commandBreakdown.mapValues {
                    BreakdownValues(raw: $0.raw, filtered: $0.filtered)
                }
            )
        }

        let tokens = Double(workspace.totalSavedBytes) / 4.0
        let costSaved = (tokens / 1_000_000) * 3.0

        let export = ExportData(
            timestamp: now,
            duration: duration,
            totalRawBytes: workspace.totalRawBytes,
            totalFilteredBytes: workspace.totalRawBytes - workspace.totalSavedBytes,
            totalSavedBytes: workspace.totalSavedBytes,
            savingsPercent: workspace.globalSavingsPercent,
            commandCount: workspace.panes.reduce(0) { $0 + $1.metrics.commandCount },
            paneCount: workspace.panes.count,
            estimatedCostSaved: costSaved,
            panes: paneExports
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(export)
    }

    /// Export current session as a markdown report string.
    func exportReport(workspace: WorkspaceModel) -> String {
        let now = Date()
        let duration = now.timeIntervalSince(workspace.sessionStart)
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60

        let tokens = Double(workspace.totalSavedBytes) / 4.0
        let costSaved = (tokens / 1_000_000) * 3.0
        let totalCommands = workspace.panes.reduce(0) { $0 + $1.metrics.commandCount }

        var lines: [String] = []
        lines.append("# Senkani Session Report")
        lines.append("")
        lines.append("**Date:** \(DateFormatter.localizedString(from: now, dateStyle: .medium, timeStyle: .short))")
        lines.append("**Duration:** \(hours > 0 ? "\(hours)h \(String(format: "%02d", minutes))m" : "\(minutes)m")")
        lines.append("**Panes:** \(workspace.panes.count)")
        lines.append("**Commands intercepted:** \(totalCommands)")
        lines.append("")
        lines.append("## Savings Summary")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append("| Raw bytes | \(workspace.totalRawBytes) |")
        lines.append("| Saved bytes | \(workspace.totalSavedBytes) |")
        lines.append("| Reduction | \(String(format: "%.1f%%", workspace.globalSavingsPercent)) |")
        lines.append("| Estimated cost saved | \(String(format: "$%.2f", costSaved)) |")
        lines.append("")

        // Per-pane breakdown
        if !workspace.panes.isEmpty {
            lines.append("## Per-Pane Breakdown")
            lines.append("")
            lines.append("| Pane | Commands | Saved | Percent |")
            lines.append("|------|----------|-------|---------|")
            for pane in workspace.panes {
                lines.append("| \(pane.title) | \(pane.metrics.commandCount) | \(pane.metrics.formattedSavings) | \(pane.metrics.formattedPercent) |")
            }
            lines.append("")
        }

        // Command breakdown across all panes
        var globalBreakdown: [String: (raw: Int, filtered: Int)] = [:]
        for pane in workspace.panes {
            for (cmd, values) in pane.metrics.commandBreakdown {
                let existing = globalBreakdown[cmd, default: (raw: 0, filtered: 0)]
                globalBreakdown[cmd] = (raw: existing.raw + values.raw, filtered: existing.filtered + values.filtered)
            }
        }

        if !globalBreakdown.isEmpty {
            lines.append("## Command Breakdown")
            lines.append("")
            lines.append("| Command | Raw | Filtered | Saved |")
            lines.append("|---------|-----|----------|-------|")
            let sorted = globalBreakdown.sorted { ($0.value.raw - $0.value.filtered) > ($1.value.raw - $1.value.filtered) }
            for (cmd, vals) in sorted {
                lines.append("| \(cmd) | \(vals.raw) | \(vals.filtered) | \(vals.raw - vals.filtered) |")
            }
            lines.append("")
        }

        lines.append("---")
        lines.append("*Generated by Senkani*")
        return lines.joined(separator: "\n")
    }
}
