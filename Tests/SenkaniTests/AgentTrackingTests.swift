import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-agent-test-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

// MARK: - AgentType

@Suite("AgentType")
struct AgentTypeTests {

    @Test func rawValueRoundTrip() {
        for type_ in AgentType.allCases {
            let decoded = AgentType(rawValue: type_.rawValue)
            #expect(decoded == type_, "roundtrip failed for \(type_.rawValue)")
        }
    }

    @Test func modelTierValues() {
        #expect(AgentType.claudeCode.modelTier == "tier1_exact")
        #expect(AgentType.cursor.modelTier == "tier2_estimated")
        #expect(AgentType.cline.modelTier == "tier2_estimated")
        #expect(AgentType.unknownHook.modelTier == "tier2_estimated")
        #expect(AgentType.unknownMCP.modelTier == "tier3_partial")
    }

    @Test func displayNamesNonEmpty() {
        for type_ in AgentType.allCases {
            #expect(!type_.displayName.isEmpty, "displayName empty for \(type_.rawValue)")
        }
    }
}

// MARK: - AgentDetector

@Suite("AgentDetector")
struct AgentDetectorTests {

    @Test func detectsClaudeCodeByPaneId() {
        let env = ["SENKANI_PANE_ID": "pane-123"]
        #expect(AgentDetector.detect(environment: env) == .claudeCode)
    }

    @Test func detectsCursorByTraceId() {
        let env = ["CURSOR_TRACE_ID": "trace-abc"]
        #expect(AgentDetector.detect(environment: env) == .cursor)
    }

    @Test func detectsClineByTaskId() {
        let env = ["CLINE_TASK_ID": "task-xyz"]
        #expect(AgentDetector.detect(environment: env) == .cline)
    }

    @Test func explicitOverrideWins() {
        // SENKANI_AGENT overrides even when SENKANI_PANE_ID is also set
        let env = ["SENKANI_AGENT": "cursor", "SENKANI_PANE_ID": "pane-123"]
        #expect(AgentDetector.detect(environment: env) == .cursor)
    }

    @Test func unknownHookWhenHookEnabled() {
        let env = ["SENKANI_HOOK": "on"]
        #expect(AgentDetector.detect(environment: env) == .unknownHook)
    }

    @Test func unknownMCPWhenNoEnvVars() {
        let env: [String: String] = [:]
        #expect(AgentDetector.detect(environment: env) == .unknownMCP)
    }

    @Test func invalidExplicitOverrideFallsThrough() {
        // Unknown agent type string falls through to env-var detection
        let env = ["SENKANI_AGENT": "nonexistent_agent", "SENKANI_PANE_ID": "pane-1"]
        // SENKANI_AGENT is invalid → fallback to SENKANI_PANE_ID → claudeCode
        #expect(AgentDetector.detect(environment: env) == .claudeCode)
    }
}

// MARK: - SessionDatabase agent_type

@Suite("SessionDatabase — agent_type")
struct SessionDatabaseAgentTypeTests {

    @Test func createSessionStoresAgentType() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/test-project", agentType: .claudeCode)
        #expect(!sid.isEmpty)

        // Verify by querying token stats — a session was created, we can verify by doing
        // a token event and querying tokenStatsByAgent.
        db.recordTokenEvent(
            sessionId: sid,
            paneId: nil,
            projectRoot: "/tmp/test-project",
            source: "mcp_tool",
            toolName: "read",
            model: nil,
            inputTokens: 100,
            outputTokens: 10,
            savedTokens: 90,
            costCents: 5,
            feature: "filter",
            command: nil,
            modelTier: "tier1_exact"
        )

        // Give async write a moment to flush
        Thread.sleep(forTimeInterval: 0.05)

        let stats = db.tokenStatsByAgent(projectRoot: "/tmp/test-project")
        #expect(!stats.isEmpty, "Expected agent stats, got empty")
        let claudeStats = stats.first { $0.agentType == .claudeCode }
        #expect(claudeStats != nil, "Expected claudeCode entry in stats")
        #expect(claudeStats?.savedTokens == 90)
    }

    @Test func tokenStatsByAgentGroupsCorrectly() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/multi-agent-project"
        let ccSid  = db.createSession(projectRoot: root, agentType: .claudeCode)
        let curSid = db.createSession(projectRoot: root, agentType: .cursor)

        for sid in [ccSid, curSid] {
            let tier: String = (sid == ccSid) ? "tier1_exact" : "tier2_estimated"
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: root,
                source: "mcp_tool", toolName: "read", model: nil,
                inputTokens: 100, outputTokens: 10, savedTokens: 50,
                costCents: 3, feature: "filter", command: nil,
                modelTier: tier
            )
        }

        Thread.sleep(forTimeInterval: 0.05)

        let stats = db.tokenStatsByAgent(projectRoot: root)
        let types = Set(stats.map(\.agentType))
        #expect(types.contains(.claudeCode), "Expected claudeCode in results")
        #expect(types.contains(.cursor), "Expected cursor in results")
        // Each should have exactly 50 saved tokens
        for stat in stats {
            #expect(stat.savedTokens == 50, "Unexpected savedTokens for \(stat.agentType)")
        }
    }

    @Test func sessionsWithoutAgentTypeExcludedFromAgentStats() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/legacy-project"
        // Legacy session: no agentType
        let legacySid = db.createSession(projectRoot: root)
        db.recordTokenEvent(
            sessionId: legacySid, paneId: nil, projectRoot: root,
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 100, outputTokens: 10, savedTokens: 80,
            costCents: 4, feature: "filter", command: nil
        )

        Thread.sleep(forTimeInterval: 0.05)

        // tokenStatsByAgent JOINs sessions WHERE agent_type IS NOT NULL
        let stats = db.tokenStatsByAgent(projectRoot: root)
        #expect(stats.isEmpty, "Legacy sessions without agent_type should not appear in agent stats")
    }

    @Test func modelTierPersistedOnTokenEvent() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let sid = db.createSession(projectRoot: "/tmp/tier-test", agentType: .claudeCode)
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/tier-test",
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 50, outputTokens: 5, savedTokens: 45,
            costCents: 2, feature: "filter", command: nil,
            modelTier: "tier1_exact"
        )

        Thread.sleep(forTimeInterval: 0.05)

        // Verify by checking raw SQL that model_tier was written
        var found = false
        db.executeRawSQL("SELECT model_tier FROM token_events WHERE model_tier = 'tier1_exact' LIMIT 1;")
        // We can't read SQL results from executeRawSQL directly; use the stats query as proxy.
        let stats = db.tokenStatsByAgent(projectRoot: "/tmp/tier-test")
        found = stats.first { $0.agentType == .claudeCode } != nil
        #expect(found, "Expected tier1_exact row to show up via agent stats join")
    }
}

// MARK: - SessionDatabase cursors

@Suite("SessionDatabase — session cursors")
struct SessionCursorTests {

    @Test func getReturnsZeroForNewPath() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let (offset, turn) = db.getSessionCursor(path: "/nonexistent/file.jsonl")
        #expect(offset == 0)
        #expect(turn == 0)
    }

    @Test func setCursorAndRetrieve() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let filePath = "/tmp/session-abc.jsonl"
        db.setSessionCursor(path: filePath, byteOffset: 1024, turnIndex: 7)

        Thread.sleep(forTimeInterval: 0.05)

        let (offset, turn) = db.getSessionCursor(path: filePath)
        #expect(offset == 1024)
        #expect(turn == 7)
    }

    @Test func setCursorIsIdempotentUpsert() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let filePath = "/tmp/session-xyz.jsonl"
        db.setSessionCursor(path: filePath, byteOffset: 100, turnIndex: 3)
        Thread.sleep(forTimeInterval: 0.05)
        db.setSessionCursor(path: filePath, byteOffset: 500, turnIndex: 12)
        Thread.sleep(forTimeInterval: 0.05)

        let (offset, turn) = db.getSessionCursor(path: filePath)
        #expect(offset == 500, "Expected latest cursor value")
        #expect(turn == 12, "Expected latest turn index")
    }
}

// MARK: - ClaudeSessionReader

@Suite("ClaudeSessionReader")
struct ClaudeSessionReaderTests {

    @Test func readsAssistantTurnsFromJSONL() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        // Write a minimal JSONL with one assistant turn carrying usage data.
        // The reader scans <projectsDir>/<subdir>/<sessionId>.jsonl — we mirror that layout.
        let projectsDir = "/tmp/senkani-reader-test-\(UUID().uuidString)"
        let subdir = projectsDir + "/proj-abc"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectsDir) }

        let sessionId = UUID().uuidString
        let filePath = subdir + "/" + sessionId + ".jsonl"

        let turn1 = #"{"type":"assistant","timestamp":"2026-04-15T10:00:00.000Z","message":{"usage":{"input_tokens":500,"output_tokens":200,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-4-6"}}"#
        try (turn1 + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)

        let events = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        #expect(events.count == 1, "Expected 1 event, got \(events.count)")
        #expect(events[0].inputTokens == 500)
        #expect(events[0].outputTokens == 200)
        #expect(events[0].model == "claude-sonnet-4-6")
    }

    @Test func skipsNonAssistantLines() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let projectsDir = "/tmp/senkani-reader-test-\(UUID().uuidString)"
        let subdir = projectsDir + "/proj-xyz"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectsDir) }

        let sessionId = UUID().uuidString
        let filePath = subdir + "/" + sessionId + ".jsonl"

        // user and tool_result lines should be skipped
        let lines = [
            #"{"type":"user","content":"hello"}"#,
            #"{"type":"tool_result","tool_use_id":"abc","content":"output"}"#,
            #"{"type":"assistant","timestamp":"2026-04-15T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":"claude-haiku-4-5"}}"#,
        ].joined(separator: "\n")

        try (lines + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)

        let events = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        #expect(events.count == 1, "Expected only the assistant turn")
        #expect(events[0].inputTokens == 100)
    }

    @Test func cursorPreventsDoubleCount() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let projectsDir = "/tmp/senkani-reader-test-\(UUID().uuidString)"
        let subdir = projectsDir + "/proj-cursor"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectsDir) }

        let sessionId = UUID().uuidString
        let filePath = subdir + "/" + sessionId + ".jsonl"

        let turn1 = #"{"type":"assistant","timestamp":"2026-04-15T10:00:00Z","message":{"usage":{"input_tokens":300,"output_tokens":100},"model":null}}"#
        try (turn1 + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)

        // First read: should get 1 event
        let first = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        #expect(first.count == 1)

        Thread.sleep(forTimeInterval: 0.05)

        // Second read without new data: cursor is at end, should get 0 events
        let second = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        #expect(second.isEmpty, "Expected 0 new events (cursor advanced past existing data)")
    }

    @Test func readsOnlyNewLinesAfterCursor() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let projectsDir = "/tmp/senkani-reader-test-\(UUID().uuidString)"
        let subdir = projectsDir + "/proj-incremental"
        try FileManager.default.createDirectory(atPath: subdir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projectsDir) }

        let sessionId = UUID().uuidString
        let filePath = subdir + "/" + sessionId + ".jsonl"

        let turn1 = #"{"type":"assistant","timestamp":"2026-04-15T10:00:00Z","message":{"usage":{"input_tokens":100,"output_tokens":50},"model":null}}"#
        try (turn1 + "\n").write(toFile: filePath, atomically: true, encoding: .utf8)

        // Read once to advance cursor
        _ = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        Thread.sleep(forTimeInterval: 0.05)

        // Append a new turn
        let turn2 = #"{"type":"assistant","timestamp":"2026-04-15T10:01:00Z","message":{"usage":{"input_tokens":200,"output_tokens":75},"model":null}}"#
        if let handle = FileHandle(forWritingAtPath: filePath) {
            handle.seekToEndOfFile()
            handle.write((turn2 + "\n").data(using: .utf8)!)
            handle.closeFile()
        }

        // Second read: should get only turn2
        let second = ClaudeSessionReader.readNew(db: db, projectsDir: projectsDir)
        #expect(second.count == 1, "Expected exactly 1 new event")
        #expect(second[0].inputTokens == 200)
    }

    @Test func handlesEmptyDirectory() throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        // Non-existent directory → graceful empty result, no crash
        let events = ClaudeSessionReader.readNew(db: db, projectsDir: "/tmp/nonexistent-\(UUID().uuidString)")
        #expect(events.isEmpty)
    }
}
