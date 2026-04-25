import Foundation

/// Result row from full-text search across commands.
public struct CommandSearchResult: Identifiable, Sendable {
    public let id: Int
    public let sessionId: String
    public let timestamp: Date
    public let toolName: String
    public let command: String?
    public let rawBytes: Int
    public let compressedBytes: Int
    public let feature: String?
    public let outputPreview: String?
}

/// Lifetime stats across all sessions.
public struct LifetimeStats: Sendable {
    public let totalSessions: Int
    public let totalCommands: Int
    public let totalRawBytes: Int
    public let totalSavedBytes: Int
    public let totalCostSavedCents: Int

    public init(totalSessions: Int, totalCommands: Int, totalRawBytes: Int, totalSavedBytes: Int, totalCostSavedCents: Int) {
        self.totalSessions = totalSessions
        self.totalCommands = totalCommands
        self.totalRawBytes = totalRawBytes
        self.totalSavedBytes = totalSavedBytes
        self.totalCostSavedCents = totalCostSavedCents
    }
}

/// Aggregated token stats for a pane or project.
public struct PaneTokenStats: Sendable, Equatable {
    public let inputTokens: Int
    public let outputTokens: Int
    public let savedTokens: Int
    public let costCents: Int
    public let commandCount: Int

    public static let zero = PaneTokenStats(inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0, commandCount: 0)
}

/// Row type returned by loadSessions — mirrors SessionSummaryRecord's public shape.
public struct SessionSummaryRow: Identifiable, Sendable {
    public let id: String
    public let timestamp: Date
    public let duration: TimeInterval
    public let totalRaw: Int
    public let totalSaved: Int
    public let commandCount: Int
    public let paneCount: Int
    public let costSavedCents: Int

    public var savingsPercent: Double {
        guard totalRaw > 0 else { return 0 }
        return Double(totalSaved) / Double(totalRaw) * 100
    }

    public var formattedSavings: String {
        if totalSaved >= 1_000_000 { return String(format: "%.1fM", Double(totalSaved) / 1_000_000) }
        if totalSaved >= 1_000 { return String(format: "%.1fK", Double(totalSaved) / 1_000) }
        return "\(totalSaved)B"
    }

    public var formattedDuration: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        return "\(minutes)m"
    }

    public var estimatedCostSaved: Double {
        ModelPricing.costSaved(bytes: totalSaved)
    }
}

extension SessionDatabase {
    @discardableResult
    public func createSession(paneCount: Int = 0, projectRoot: String? = nil, agentType: AgentType? = nil) -> String {
        commandStore.createSession(paneCount: paneCount, projectRoot: projectRoot, agentType: agentType)
    }

    public func recordCommand(
        sessionId: String,
        toolName: String,
        command: String?,
        rawBytes: Int,
        compressedBytes: Int,
        feature: String? = nil,
        outputPreview: String? = nil
    ) {
        commandStore.recordCommand(
            sessionId: sessionId,
            toolName: toolName,
            command: command,
            rawBytes: rawBytes,
            compressedBytes: compressedBytes,
            feature: feature,
            outputPreview: outputPreview
        )
    }

    public func endSession(sessionId: String) {
        commandStore.endSession(sessionId: sessionId)
    }

    public func loadSessions(limit: Int = 50) -> [SessionSummaryRow] {
        commandStore.loadSessions(limit: limit)
    }

    public func search(query: String, limit: Int = 50) -> [CommandSearchResult] {
        commandStore.search(query: query, limit: limit)
    }

    public func totalStats() -> LifetimeStats {
        commandStore.totalStats()
    }

    public func statsForProject(_ projectRoot: String) -> LifetimeStats {
        commandStore.statsForProject(projectRoot)
    }

    public func recentStats(since: Date) -> LifetimeStats {
        commandStore.recentStats(since: since)
    }

    public func commandBreakdown(projectRoot: String) -> [(command: String, rawBytes: Int, compressedBytes: Int)] {
        commandStore.commandBreakdown(projectRoot: projectRoot)
    }

    public func outputPreviewsForCommand(
        projectRoot: String?,
        commandPrefix: String,
        limit: Int = 20
    ) -> [String] {
        commandStore.outputPreviewsForCommand(
            projectRoot: projectRoot,
            commandPrefix: commandPrefix,
            limit: limit
        )
    }

    public func costForToday() -> Int {
        commandStore.costForToday()
    }

    public func costForWeek() -> Int {
        commandStore.costForWeek()
    }

    public func recordBudgetDecision(
        sessionId: String,
        toolName: String,
        decision: String,
        rawBytes: Int = 0,
        compressedBytes: Int = 0
    ) {
        commandStore.recordBudgetDecision(
            sessionId: sessionId,
            toolName: toolName,
            decision: decision,
            rawBytes: rawBytes,
            compressedBytes: compressedBytes
        )
    }

    public func executeRawSQL(_ sql: String) {
        commandStore.executeRawSQL(sql)
    }

    static func sanitizeFTS5Query(_ raw: String) -> String {
        CommandStore.sanitizeFTS5Query(raw)
    }
}
