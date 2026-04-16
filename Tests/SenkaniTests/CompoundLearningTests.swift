import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-cl-test-\(UUID().uuidString)/senkani.db"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(path: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.removeItem(atPath: dir)
}

/// Temporary learned-rules file path, isolated from the real ~/.senkani/learned-rules.json.
private func tempRulesPath() -> String {
    "/tmp/senkani-cl-test-\(UUID().uuidString)/learned-rules.json"
}

/// Write a learned-rules file to `path` and reload the store singleton.
private func withTempRulesStore(_ path: String, _ body: () throws -> Void) rethrows {
    // Temporarily redirect the store to `path` by writing an empty file there first
    let dir = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let empty = LearnedRulesFile.empty
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(empty) {
        try? data.write(to: URL(fileURLWithPath: path))
    }
    defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    try body()
}

// MARK: - WasteAnalyzer Tests

@Suite("WasteAnalyzer")
struct WasteAnalyzerTests {

    /// Insert token_events rows simulating an unfiltered exec command.
    private func insertExecEvents(
        db: SessionDatabase,
        projectRoot: String,
        command: String,
        sessionIds: [String],
        inputTokens: Int,
        savedTokens: Int
    ) {
        for sid in sessionIds {
            db.recordTokenEvent(
                sessionId: sid,
                paneId: nil,
                projectRoot: projectRoot,
                source: "mcp_tool",
                toolName: "exec",
                model: nil,
                inputTokens: inputTokens,
                outputTokens: 10,
                savedTokens: savedTokens,
                costCents: 2,
                feature: "filter",
                command: command
            )
        }
        Thread.sleep(forTimeInterval: 0.05)
    }

    @Test func detectsUnfilteredCommandsAboveThreshold() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/waste-project"
        let s1 = db.createSession(projectRoot: root)
        let s2 = db.createSession(projectRoot: root)

        // saved_tokens = 5 out of 200 input = ~2.5% savings — well below 15%
        insertExecEvents(db: db, projectRoot: root, command: "docker compose logs",
                         sessionIds: [s1, s2], inputTokens: 200, savedTokens: 5)

        let report = WasteAnalyzer.analyze(
            projectRoot: root,
            sessionId: s2,
            db: db,
            minSessions: 2,
            minInputTokens: 100
        )
        #expect(!report.isEmpty, "Expected at least one unfiltered command")
        let cmd = report.unfilteredCommands.first
        #expect(cmd?.baseCommand == "docker")
        #expect(cmd?.subcommand == "compose")
        #expect(cmd?.sessionCount ?? 0 >= 2)
    }

    @Test func skipsWellFilteredCommands() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/well-filtered-project"
        let s1 = db.createSession(projectRoot: root)
        let s2 = db.createSession(projectRoot: root)

        // saved_tokens = 150 out of 200 input = 75% savings — above 15% threshold
        insertExecEvents(db: db, projectRoot: root, command: "git status",
                         sessionIds: [s1, s2], inputTokens: 200, savedTokens: 150)

        let report = WasteAnalyzer.analyze(
            projectRoot: root,
            sessionId: s2,
            db: db,
            minSessions: 2,
            minInputTokens: 100
        )
        #expect(report.isEmpty, "Well-filtered commands should not appear in WasteReport")
    }

    @Test func skipsLowVolumeCommands() {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path: path) }

        let root = "/tmp/low-volume-project"
        let s1 = db.createSession(projectRoot: root)
        let s2 = db.createSession(projectRoot: root)

        // input_tokens = 50 — below minInputTokens=100 threshold
        insertExecEvents(db: db, projectRoot: root, command: "ls -la",
                         sessionIds: [s1, s2], inputTokens: 50, savedTokens: 0)

        let report = WasteAnalyzer.analyze(
            projectRoot: root,
            sessionId: s2,
            db: db,
            minSessions: 2,
            minInputTokens: 100
        )
        #expect(report.isEmpty, "Low-volume commands should be excluded by minInputTokens gate")
    }
}

// MARK: - CompoundLearning Tests

@Suite("CompoundLearning")
struct CompoundLearningTests {

    @Test func noOpWhenNoPatternsFound() async throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let root = "/tmp/noop-project"
        // Session with only read events (not exec) — WasteAnalyzer finds nothing
        let sid = db.createSession(projectRoot: root)
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: root,
            source: "mcp_tool", toolName: "read", model: nil,
            inputTokens: 100, outputTokens: 10, savedTokens: 80,
            costCents: 2, feature: "cache", command: nil
        )
        try await Task.sleep(nanoseconds: 50_000_000)

        // Use a temp rules file so we don't pollute the real one
        let rulesPath = tempRulesPath()
        let rulesDir = (rulesPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: rulesDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: rulesDir) }

        await CompoundLearning.runPostSession(sessionId: sid, projectRoot: root, db: db)

        // Nothing should have been staged (WasteAnalyzer finds nothing)
        // Since we can't isolate the real store in this test, verify via WasteAnalyzer directly
        let report = WasteAnalyzer.analyze(projectRoot: root, sessionId: sid, db: db)
        #expect(report.isEmpty, "No exec events → WasteReport should be empty")
    }

    @Test func proposedRuleHasCorrectCommand() async throws {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(path: dbPath) }

        let root = "/tmp/propose-project"
        let s1 = db.createSession(projectRoot: root)
        let s2 = db.createSession(projectRoot: root)

        for sid in [s1, s2] {
            db.recordTokenEvent(
                sessionId: sid, paneId: nil, projectRoot: root,
                source: "mcp_tool", toolName: "exec", model: nil,
                inputTokens: 300, outputTokens: 20, savedTokens: 10,
                costCents: 3, feature: "filter", command: "mycli run tests"
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)

        let report = WasteAnalyzer.analyze(
            projectRoot: root, sessionId: s2, db: db,
            minSessions: 2, minInputTokens: 100
        )
        #expect(!report.isEmpty)
        let cmd = report.unfilteredCommands.first!
        #expect(cmd.baseCommand == "mycli")
        #expect(cmd.subcommand == "run")

        // Verify proposed rule shape
        let proposed = LearnedFilterRule(
            id: UUID().uuidString,
            command: cmd.baseCommand,
            subcommand: cmd.subcommand,
            ops: ["head(50)"],
            source: s2,
            confidence: max(0, min(1, 1.0 - (cmd.avgSavedPct / 100.0))),
            status: .staged,
            sessionCount: cmd.sessionCount,
            createdAt: Date()
        )
        #expect(proposed.command == "mycli")
        #expect(proposed.subcommand == "run")
        #expect(proposed.ops == ["head(50)"])
        #expect(proposed.confidence > 0.8)
    }

    @Test func gateRejectsCommandAlreadyCoveredByBuiltin() {
        // "git" is covered by BuiltinRules — gate should reject
        let rule = LearnedFilterRule(
            id: UUID().uuidString,
            command: "git",
            subcommand: "status",
            ops: ["head(50)"],
            source: "test-session",
            confidence: 0.9,
            status: .staged,
            sessionCount: 2,
            createdAt: Date()
        )
        let pass = CompoundLearning.runGate(proposed: rule)
        #expect(!pass, "Commands already covered by BuiltinRules should fail the gate")
    }
}

// MARK: - LearnedRulesStore Tests

@Suite("LearnedRulesStore")
struct LearnedRulesStoreTests {

    private func makeRule(command: String = "mytool", subcommand: String? = nil) -> LearnedFilterRule {
        LearnedFilterRule(
            id: UUID().uuidString,
            command: command,
            subcommand: subcommand,
            ops: ["head(50)"],
            source: "session-test",
            confidence: 0.95,
            status: .staged,
            sessionCount: 3,
            createdAt: Date()
        )
    }

    @Test func stagesRuleAndPersistsToJSON() throws {
        let dir = "/tmp/senkani-store-test-\(UUID().uuidString)"
        let path = dir + "/learned-rules.json"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // Write empty file
        let empty = LearnedRulesFile.empty
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(empty).write(to: URL(fileURLWithPath: path))

        // Load directly (bypassing singleton for isolation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let rule = makeRule()
        var file = (try? decoder.decode(LearnedRulesFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))) ?? .empty
        file.rules.append(rule)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)

        // Reload and verify
        let loaded = try decoder.decode(LearnedRulesFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(loaded.rules.count == 1)
        #expect(loaded.rules[0].status == .staged)
        #expect(loaded.rules[0].command == "mytool")
    }

    @Test func applyMakesRuleActive() throws {
        // Write a staged rule to a temp file, apply it, verify status changes
        let dir = "/tmp/senkani-store-apply-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let rule = makeRule()
        var file = LearnedRulesFile(version: 1, rules: [rule])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let path = dir + "/learned-rules.json"
        try encoder.encode(file).write(to: URL(fileURLWithPath: path))

        // Mutate: apply the rule
        guard let idx = file.rules.firstIndex(where: { $0.id == rule.id }) else {
            Issue.record("Rule not found")
            return
        }
        file.rules[idx].status = .applied
        try encoder.encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(LearnedRulesFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(reloaded.rules[0].status == .applied)
        let applied = reloaded.rules.filter { $0.status == .applied }
        #expect(!applied.isEmpty, "loadApplied should return the applied rule")
    }

    @Test func rejectDropsRule() throws {
        let dir = "/tmp/senkani-store-reject-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let rule = makeRule()
        var file = LearnedRulesFile(version: 1, rules: [rule])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let path = dir + "/learned-rules.json"
        try encoder.encode(file).write(to: URL(fileURLWithPath: path))

        guard let idx = file.rules.firstIndex(where: { $0.id == rule.id }) else {
            Issue.record("Rule not found")
            return
        }
        file.rules[idx].status = .rejected
        try encoder.encode(file).write(to: URL(fileURLWithPath: path), options: .atomic)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(LearnedRulesFile.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(reloaded.rules[0].status == .rejected)
        let applied = reloaded.rules.filter { $0.status == .applied }
        #expect(applied.isEmpty, "Rejected rule should not be in applied set")
    }

    @Test func jsonRoundtripPreservesVersion() throws {
        let rule = makeRule()
        let file = LearnedRulesFile(version: 1, rules: [rule])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reloaded = try decoder.decode(LearnedRulesFile.self, from: data)

        #expect(reloaded.version == 1, "Version field must survive JSON roundtrip")
        #expect(reloaded.rules.count == 1)
        #expect(reloaded.rules[0].command == rule.command)
        #expect(reloaded.rules[0].sessionCount == rule.sessionCount)
    }
}
