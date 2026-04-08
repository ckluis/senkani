import Foundation
import Core

/// Persisted summary of a past session.
/// Bridges between SessionDatabase rows and the app UI.
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
        ModelPricing.costSaved(bytes: totalSaved)
    }

    /// Create from a database row.
    init(from row: SessionSummaryRow) {
        self.filename = row.id
        self.timestamp = row.timestamp
        self.duration = row.duration
        self.totalSaved = row.totalSaved
        self.totalRaw = row.totalRaw
        self.commandCount = row.commandCount
        self.paneCount = row.paneCount
    }

    init(filename: String, timestamp: Date, duration: TimeInterval,
         totalSaved: Int, totalRaw: Int, commandCount: Int, paneCount: Int) {
        self.filename = filename
        self.timestamp = timestamp
        self.duration = duration
        self.totalSaved = totalSaved
        self.totalRaw = totalRaw
        self.commandCount = commandCount
        self.paneCount = paneCount
    }
}

/// Search result wrapping a CommandSearchResult for display.
struct CommandSearchResultRecord: Identifiable {
    let id: Int
    let sessionId: String
    let timestamp: Date
    let toolName: String
    let command: String?
    let rawBytes: Int
    let compressedBytes: Int
    let outputPreview: String?

    init(from result: CommandSearchResult) {
        self.id = result.id
        self.sessionId = result.sessionId
        self.timestamp = result.timestamp
        self.toolName = result.toolName
        self.command = result.command
        self.rawBytes = result.rawBytes
        self.compressedBytes = result.compressedBytes
        self.outputPreview = result.outputPreview
    }
}

/// Manages persistence and retrieval of session history.
/// Now backed by SQLite+FTS5 via SessionDatabase.
@MainActor @Observable
final class SessionStore {
    static let shared = SessionStore()

    var pastSessions: [SessionSummaryRecord] = []
    var searchResults: [CommandSearchResultRecord] = []

    /// ID of the currently active database session (set when app starts).
    private(set) var activeSessionId: String?

    private let database = SessionDatabase.shared

    init() {
        loadHistory()
    }

    // MARK: - Load

    func loadHistory() {
        let rows = database.loadSessions(limit: 100)
        pastSessions = rows.map { SessionSummaryRecord(from: $0) }
    }

    // MARK: - Save

    func saveSession(workspace: WorkspaceModel) {
        let now = Date()
        let duration = now.timeIntervalSince(workspace.sessionStart)
        let totalCommands = workspace.panes.reduce(0) { $0 + $1.metrics.commandCount }

        // Create a session in the database, tagged with the active project's path
        let activeProjectRoot = workspace.projects.first(where: { $0.isActive })?.path
        let sessionId = database.createSession(paneCount: workspace.panes.count, projectRoot: activeProjectRoot)

        // Record all command-level data from each pane's breakdown
        for pane in workspace.panes {
            for (cmd, values) in pane.metrics.commandBreakdown {
                database.recordCommand(
                    sessionId: sessionId,
                    toolName: cmd,
                    command: cmd,
                    rawBytes: values.raw,
                    compressedBytes: values.filtered
                )
            }
        }

        // End session to compute duration
        database.endSession(sessionId: sessionId)

        // Insert into local list
        let record = SessionSummaryRecord(
            filename: sessionId,
            timestamp: now,
            duration: duration,
            totalSaved: workspace.totalSavedBytes,
            totalRaw: workspace.totalRawBytes,
            commandCount: totalCommands,
            paneCount: workspace.panes.count
        )
        pastSessions.insert(record, at: 0)
    }

    /// Begin tracking a live session — call on app launch.
    func beginLiveSession(paneCount: Int, projectRoot: String? = nil) {
        activeSessionId = database.createSession(paneCount: paneCount, projectRoot: projectRoot)
    }

    /// Record a command into the active session.
    func recordCommand(toolName: String, command: String?, rawBytes: Int, compressedBytes: Int, feature: String? = nil, outputPreview: String? = nil) {
        guard let sessionId = activeSessionId else { return }
        database.recordCommand(
            sessionId: sessionId,
            toolName: toolName,
            command: command,
            rawBytes: rawBytes,
            compressedBytes: compressedBytes,
            feature: feature,
            outputPreview: outputPreview
        )
    }

    /// End the active live session.
    func endLiveSession() {
        if let sessionId = activeSessionId {
            database.endSession(sessionId: sessionId)
            activeSessionId = nil
            loadHistory()
        }
    }

    // MARK: - Search (FTS5)

    func search(query: String) {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            searchResults = []
            return
        }
        let results = database.search(query: query, limit: 50)
        searchResults = results.map { CommandSearchResultRecord(from: $0) }
    }

    // MARK: - Lifetime Stats

    func lifetimeStats() -> LifetimeStats {
        database.totalStats()
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

        let costSaved = ModelPricing.costSaved(bytes: workspace.totalSavedBytes)

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

        let costSaved = ModelPricing.costSaved(bytes: workspace.totalSavedBytes)
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
