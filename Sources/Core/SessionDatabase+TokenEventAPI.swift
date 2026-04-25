import Foundation

extension SessionDatabase {
    /// Per-feature token savings breakdown for a project.
    public struct FeatureSavings: Sendable, Equatable {
        public let feature: String
        public let savedTokens: Int
        public let inputTokens: Int
        public let outputTokens: Int
        public let eventCount: Int

        public init(feature: String, savedTokens: Int, inputTokens: Int, outputTokens: Int, eventCount: Int) {
            self.feature = feature
            self.savedTokens = savedTokens
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.eventCount = eventCount
        }
    }

    /// A single token event row from the database, with fields the timeline pane needs to render.
    public struct TimelineEvent: Sendable, Equatable, Identifiable {
        public let id: Int64
        public let timestamp: Date
        public let source: String
        public let toolName: String?
        public let feature: String?
        public let command: String?
        public let inputTokens: Int
        public let outputTokens: Int
        public let savedTokens: Int
        public let costCents: Int

        public init(id: Int64, timestamp: Date, source: String, toolName: String?,
                    feature: String?, command: String?, inputTokens: Int,
                    outputTokens: Int, savedTokens: Int, costCents: Int) {
            self.id = id
            self.timestamp = timestamp
            self.source = source
            self.toolName = toolName
            self.feature = feature
            self.command = command
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.savedTokens = savedTokens
            self.costCents = costCents
        }
    }

    /// Per-session savings summary: total raw, total saved, multiplier.
    public struct SessionSummary: Sendable {
        public let sessionId: String
        public let startedAt: Date
        public let totalRawTokens: Int
        public let totalSavedTokens: Int
        public var multiplier: Double {
            let compressed = totalRawTokens - totalSavedTokens
            return compressed > 0 ? Double(totalRawTokens) / Double(compressed) : 1.0
        }
    }

    /// Row returned by the waste-analysis query.
    public struct UnfilteredCommandRow: Sendable {
        public let command: String
        public let sessionCount: Int
        public let avgInputTokens: Int
        public let avgSavedPct: Double
    }

    /// H+2b — recurring file-path mentions for context-signal generation.
    public struct RecurringFileRow: Sendable {
        public let path: String
        public let sessionCount: Int
        public let mentionCount: Int
    }

    /// H+2c — commands that retried within a single session.
    public struct InstructionRetryRow: Sendable {
        public let toolName: String
        public let command: String
        public let sessionCount: Int
        public let avgRetries: Double
    }

    /// H+2c — ordered tool-call pairs (A, B) across sessions.
    public struct WorkflowPairRow: Sendable {
        public let firstTool: String
        public let secondTool: String
        public let sessionCount: Int
        public let totalOccurrences: Int
    }

    public func recordTokenEvent(
        sessionId: String,
        paneId: String?,
        projectRoot: String?,
        source: String,
        toolName: String?,
        model: String?,
        inputTokens: Int,
        outputTokens: Int,
        savedTokens: Int,
        costCents: Int,
        feature: String?,
        command: String?,
        modelTier: String? = nil
    ) {
        tokenEventStore.recordTokenEvent(
            sessionId: sessionId, paneId: paneId, projectRoot: projectRoot,
            source: source, toolName: toolName, model: model,
            inputTokens: inputTokens, outputTokens: outputTokens,
            savedTokens: savedTokens, costCents: costCents,
            feature: feature, command: command, modelTier: modelTier
        )
    }

    public func tokenStatsForProject(_ projectRoot: String, since: Date? = nil) -> PaneTokenStats {
        tokenEventStore.tokenStatsForProject(projectRoot, since: since)
    }

    public func tokenStatsAllProjects() -> PaneTokenStats {
        tokenEventStore.tokenStatsAllProjects()
    }

    public func tokenStatsByFeature(projectRoot: String, since: Date? = nil) -> [FeatureSavings] {
        tokenEventStore.tokenStatsByFeature(projectRoot: projectRoot, since: since)
    }

    public func liveSessionMultiplier(projectRoot: String, since: Date? = nil) -> Double? {
        tokenEventStore.liveSessionMultiplier(projectRoot: projectRoot, since: since)
    }

    public func savingsTimeSeries(projectRoot: String, since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        tokenEventStore.savingsTimeSeries(projectRoot: projectRoot, since: since)
    }

    public func recentTokenEvents(projectRoot: String, limit: Int = 100) -> [TimelineEvent] {
        tokenEventStore.recentTokenEvents(projectRoot: projectRoot, limit: limit)
    }

    public func recentTokenEventsAllProjects(limit: Int = 100) -> [TimelineEvent] {
        tokenEventStore.recentTokenEventsAllProjects(limit: limit)
    }

    public func lastReadTimestamp(filePath: String, projectRoot: String) -> Date? {
        tokenEventStore.lastReadTimestamp(filePath: filePath, projectRoot: projectRoot)
    }

    #if DEBUG
    public func dumpTokenEvents() {
        tokenEventStore.dumpTokenEvents()
    }
    #endif

    public func tokenStatsByFeatureAllProjects(since: Date? = nil) -> [FeatureSavings] {
        tokenEventStore.tokenStatsByFeatureAllProjects(since: since)
    }

    public func savingsTimeSeriesAllProjects(since: Date? = nil) -> [(timestamp: Date, cumulativeRaw: Int, cumulativeSaved: Int)] {
        tokenEventStore.savingsTimeSeriesAllProjects(since: since)
    }

    public func hotFiles(projectRoot: String, limit: Int = 50, sinceDaysAgo: Int = 7) -> [(path: String, freq: Int)] {
        tokenEventStore.hotFiles(projectRoot: projectRoot, limit: limit, sinceDaysAgo: sinceDaysAgo)
    }

    public func sessionSummaries(projectRoot: String, limit: Int = 20) -> [SessionSummary] {
        tokenEventStore.sessionSummaries(projectRoot: projectRoot, limit: limit)
    }

    public func getSessionCursor(path: String) -> (byteOffset: Int, turnIndex: Int) {
        tokenEventStore.getSessionCursor(path: path)
    }

    public func setSessionCursor(path: String, byteOffset: Int, turnIndex: Int) {
        tokenEventStore.setSessionCursor(path: path, byteOffset: byteOffset, turnIndex: turnIndex)
    }

    public func unfilteredExecCommands(
        projectRoot: String,
        minSessions: Int = 2,
        minInputTokens: Int = 100
    ) -> [UnfilteredCommandRow] {
        tokenEventStore.unfilteredExecCommands(
            projectRoot: projectRoot,
            minSessions: minSessions,
            minInputTokens: minInputTokens
        )
    }

    public func recurringFileMentions(
        projectRoot: String,
        minSessions: Int = 3,
        limit: Int = 20
    ) -> [RecurringFileRow] {
        tokenEventStore.recurringFileMentions(
            projectRoot: projectRoot,
            minSessions: minSessions,
            limit: limit
        )
    }

    public func instructionRetryPatterns(
        projectRoot: String,
        minRetries: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [InstructionRetryRow] {
        tokenEventStore.instructionRetryPatterns(
            projectRoot: projectRoot,
            minRetries: minRetries,
            minSessions: minSessions,
            limit: limit
        )
    }

    public func workflowPairPatterns(
        projectRoot: String,
        windowSeconds: Double = 60.0,
        minOccurrencesPerSession: Int = 3,
        minSessions: Int = 2,
        limit: Int = 10
    ) -> [WorkflowPairRow] {
        tokenEventStore.workflowPairPatterns(
            projectRoot: projectRoot,
            windowSeconds: windowSeconds,
            minOccurrencesPerSession: minOccurrencesPerSession,
            minSessions: minSessions,
            limit: limit
        )
    }

    public func recordHookEvent(
        sessionId: String,
        toolName: String,
        eventType: String,
        projectRoot: String?
    ) {
        tokenEventStore.recordHookEvent(
            sessionId: sessionId,
            toolName: toolName,
            eventType: eventType,
            projectRoot: projectRoot
        )
    }

    @discardableResult
    public func pruneTokenEvents(olderThanDays: Int = 90) -> Int {
        tokenEventStore.pruneTokenEvents(olderThanDays: olderThanDays)
    }
}
