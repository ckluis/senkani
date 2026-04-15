import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeActivity(
    duration: TimeInterval = 2520,  // 42 minutes
    commandCount: Int = 18,
    savedTokens: Int = 6100,
    rawTokens: Int = 10000,
    lastCommand: String? = "git diff --stat",
    searches: [String] = ["filterEnabled", "warmIndex"],
    hotFiles: [String] = ["Sources/Core/MCPSession.swift", "Sources/Core/SessionDatabase.swift", "Sources/MCP/ToolRouter.swift"]
) -> SessionDatabase.LastSessionActivity {
    SessionDatabase.LastSessionActivity(
        sessionId: UUID().uuidString,
        startedAt: Date().addingTimeInterval(-duration),
        endedAt: Date(),
        durationSeconds: duration,
        commandCount: commandCount,
        totalSavedTokens: savedTokens,
        totalRawTokens: rawTokens,
        lastCommand: lastCommand,
        recentSearchQueries: searches,
        topHotFiles: hotFiles
    )
}

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-brief-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

// MARK: - Suite 1: Generator (Pure Function)

@Suite("SessionBriefGenerator")
struct SessionBriefGeneratorTests {

    @Test func emptyBriefWhenNoActivity() {
        let result = SessionBriefGenerator.generate(lastActivity: nil)
        #expect(result.isEmpty, "No activity should produce empty brief")
    }

    @Test func section1FormatWithAllFields() {
        let activity = makeActivity()
        let result = SessionBriefGenerator.generate(lastActivity: activity)

        #expect(result.contains("42m"), "Should mention duration")
        #expect(result.contains("18 tool calls"), "Should mention command count")
        #expect(result.contains("61%"), "Should mention savings percentage")
        #expect(result.contains("MCPSession.swift"), "Should list hot file")
        #expect(result.contains("SessionDatabase.swift"), "Should list hot file")
        #expect(result.contains("git diff"), "Should mention last command")
    }

    @Test func section2ChangedFilesIncluded() {
        let activity = makeActivity()
        let result = SessionBriefGenerator.generate(
            lastActivity: activity,
            changedFilesSinceLastSession: ["Sources/MCP/MCPMain.swift", "README.md"]
        )
        #expect(result.contains("Changed since last session"), "Should include changed files section")
        #expect(result.contains("MCPMain.swift"), "Should list changed file")
        #expect(result.contains("README.md"), "Should list changed file")
    }

    @Test func section2SkippedWhenNoChanges() {
        let activity = makeActivity()
        let result = SessionBriefGenerator.generate(lastActivity: activity, changedFilesSinceLastSession: [])
        #expect(!result.contains("Changed since"), "Should not include changed files when empty")
    }

    @Test func section3FocusHintWithSearchQueries() {
        let activity = makeActivity(searches: ["filterEnabled", "warmIndex"])
        let result = SessionBriefGenerator.generate(lastActivity: activity)
        #expect(result.contains("Recent searches"), "Should include search queries")
        #expect(result.contains("filterEnabled"), "Should include search term")
    }

    @Test func section3SkippedWhenNoSearches() {
        let activity = makeActivity(searches: [])
        let result = SessionBriefGenerator.generate(lastActivity: activity)
        #expect(!result.contains("searches"), "Should not mention searches when empty")
    }

    @Test func tokenBudgetEnforced() {
        // Create activity with lots of data
        let longFiles = (0..<20).map { "Sources/VeryLong/Path/To/File\($0).swift" }
        let longSearches = (0..<10).map { "veryLongSearchQuery\($0)WithExtraText" }
        let activity = makeActivity(searches: longSearches, hotFiles: longFiles)
        let changedFiles = (0..<50).map { "ChangedFile\($0).swift" }

        let result = SessionBriefGenerator.generate(
            lastActivity: activity,
            changedFilesSinceLastSession: changedFiles,
            maxTokens: 170
        )

        let estimatedTokens = result.count / 4
        #expect(estimatedTokens <= 170, "Brief should be within token budget, got ~\(estimatedTokens)")
    }

    @Test func tokenBudgetDropsSection3First() {
        let activity = makeActivity(searches: ["queryA", "queryB"])
        let result = SessionBriefGenerator.generate(lastActivity: activity, maxTokens: 60)

        // Section 1 should be present (it's highest priority)
        #expect(result.contains("Last session"), "Section 1 should survive budget cuts")
    }

    @Test func filePathsReducedToFilenames() {
        let activity = makeActivity(hotFiles: ["/Users/clank/Desktop/projects/senkani/Sources/Core/SessionDatabase.swift"])
        let result = SessionBriefGenerator.generate(lastActivity: activity)

        #expect(result.contains("SessionDatabase.swift"), "Should show filename")
        #expect(!result.contains("/Users/clank"), "Should NOT include full path")
    }

    @Test func zeroCommandSession() {
        let activity = makeActivity(commandCount: 0, savedTokens: 0, rawTokens: 0,
                                     lastCommand: nil, searches: [], hotFiles: [])
        let result = SessionBriefGenerator.generate(lastActivity: activity)

        #expect(!result.isEmpty, "Should still generate brief for zero-command session")
        #expect(result.contains("0 tool calls"), "Should show zero commands")
    }
}

// MARK: - Suite 2: DB Query

@Suite("SessionDatabase — Last Session Activity")
struct LastSessionActivityDBTests {

    @Test func returnsCompletedSession() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Create and end a session
        let sid1 = db.createSession(projectRoot: "/tmp/test")
        db.recordTokenEvent(
            sessionId: sid1, paneId: nil, projectRoot: "/tmp/test",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 100, outputTokens: 50, savedTokens: 30,
            costCents: 1, feature: "cache", command: "Sources/main.swift"
        )
        Thread.sleep(forTimeInterval: 0.1)
        db.endSession(sessionId: sid1)
        Thread.sleep(forTimeInterval: 0.1)

        // Create current session (not ended)
        _ = db.createSession(projectRoot: "/tmp/test")

        let activity = db.lastSessionActivity(projectRoot: "/tmp/test")
        #expect(activity != nil, "Should return the completed session")
        #expect(activity?.sessionId == sid1, "Should be the first session, not the current one")
    }

    @Test func nilWhenNoCompletedSessions() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        // Create session but don't end it
        _ = db.createSession(projectRoot: "/tmp/test")

        let activity = db.lastSessionActivity(projectRoot: "/tmp/test")
        #expect(activity == nil, "Should return nil when no completed sessions")
    }

    @Test func extractsSearchQueries() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/test")
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/test",
            source: "mcp_tool", toolName: "search", model: nil,
            inputTokens: 10, outputTokens: 5, savedTokens: 5,
            costCents: 0, feature: "indexer", command: "filterEnabled"
        )
        Thread.sleep(forTimeInterval: 0.1)
        db.endSession(sessionId: sid)
        Thread.sleep(forTimeInterval: 0.1)

        let activity = db.lastSessionActivity(projectRoot: "/tmp/test")
        #expect(activity != nil)
        #expect(activity?.recentSearchQueries.contains("filterEnabled") == true,
                "Should extract search queries from token_events")
    }
}

// MARK: - Suite 3: Integration

@Suite("SessionBriefGenerator — File Change Detection")
struct FileChangeDetectionTests {

    @Test func filesChangedSinceDetectsModified() {
        let dir = "/tmp/senkani-brief-files-\(UUID().uuidString)"
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let file1 = dir + "/unchanged.swift"
        let file2 = dir + "/modified.swift"
        FileManager.default.createFile(atPath: file1, contents: Data("// v1".utf8))
        FileManager.default.createFile(atPath: file2, contents: Data("// v1".utf8))

        let beforeModification = Date()
        Thread.sleep(forTimeInterval: 0.1)

        // Modify file2
        try! Data("// v2 - modified".utf8).write(to: URL(fileURLWithPath: file2))

        let changed = SessionBriefGenerator.filesChangedSince(
            files: [file1, file2],
            since: beforeModification,
            projectRoot: dir
        )

        #expect(changed.count == 1, "Only modified file should be detected")
        #expect(changed.first == file2, "Should detect the modified file")
    }
}
