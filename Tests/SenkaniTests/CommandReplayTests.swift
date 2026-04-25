import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-replay-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeTempDir() -> String {
    let path = "/tmp/senkani-replay-dir-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

/// Insert a fake exec event into token_events + commands tables.
private func insertExecEvent(
    db: SessionDatabase,
    command: String,
    projectRoot: String,
    timestamp: Date = Date(),
    outputPreview: String? = "All tests passed"
) {
    let sessionId = db.createSession(projectRoot: projectRoot)

    // Write to token_events (provides timestamp + project_root filter)
    db.recordTokenEvent(
        sessionId: sessionId,
        paneId: nil,
        projectRoot: projectRoot,
        source: "mcp_tool",
        toolName: "exec",
        model: nil,
        inputTokens: 100,
        outputTokens: 50,
        savedTokens: 50,
        costCents: 1,
        feature: "exec",
        command: command
    )

    // Write to commands table (provides output_preview)
    db.recordCommand(
        sessionId: sessionId,
        toolName: "exec",
        command: command,
        rawBytes: 1000,
        compressedBytes: 500,
        feature: "exec",
        outputPreview: outputPreview
    )

    // Flush async writes
    _ = db.tokenStatsAllProjects()
    // Small sleep to ensure async queue.async writes complete
    Thread.sleep(forTimeInterval: 0.05)
}

/// Set directory mtime to a specific date.
private func setDirMtime(_ path: String, to date: Date) {
    let attrs: [FileAttributeKey: Any] = [.modificationDate: date]
    try? FileManager.default.setAttributes(attrs, ofItemAtPath: path)
}

private func parseResponse(_ data: Data) -> (decision: String?, reason: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
        return (nil, nil)
    }
    return (hookOutput["permissionDecision"] as? String,
            hookOutput["permissionDecisionReason"] as? String)
}

// MARK: - Tests

@Suite("HookRouter — Command Replay")
struct CommandReplayTests {

    @Test func replayableCommandWithNoChangesReturnsDeny() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        let execTime = Date().addingTimeInterval(-30)  // 30s ago
        insertExecEvent(db: db, command: "swift test", projectRoot: dir, outputPreview: "148 passed, 2 failed")

        // Set dir mtime to BEFORE the exec (no files changed)
        setDirMtime(dir, to: execTime.addingTimeInterval(-10))

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: "test-sid",
            eventName: "PreToolUse",
            db: db
        )

        #expect(result != nil, "Should return a replay deny")

        let (decision, reason) = parseResponse(result!)
        #expect(decision == "deny", "Should be a deny decision")
        #expect(reason?.contains("already run") == true, "Should mention already run")
        #expect(reason?.contains("no source files have changed") == true, "Should mention no changes")
        #expect(reason?.contains("148 passed") == true, "Should contain output preview")
    }

    @Test func replayableCommandWithChangesReturnsNil() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        // Touch a file in the dir (updates dir mtime to NOW — after the exec)
        FileManager.default.createFile(atPath: dir + "/changed.swift", contents: Data("// changed".utf8))

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: "test-sid",
            eventName: "PreToolUse",
            db: db
        )

        #expect(result == nil, "Should NOT replay when files changed")
    }

    @Test func nonReplayableCommandNeverReplays() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        insertExecEvent(db: db, command: "curl https://example.com", projectRoot: dir)
        setDirMtime(dir, to: Date().addingTimeInterval(-60))

        let result = HookRouter.checkCommandReplay(
            command: "curl https://example.com",
            projectRoot: dir,
            sessionId: "test-sid",
            eventName: "PreToolUse",
            db: db
        )

        #expect(result == nil, "curl should never be replayed")
    }

    @Test func replayCheckFiresBeforePassthrough() {
        // "swift test" is in BOTH passthrough and replayable lists.
        // Replay should fire FIRST (before passthrough check).
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        insertExecEvent(db: db, command: "swift test", projectRoot: dir)
        setDirMtime(dir, to: Date().addingTimeInterval(-60))

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )

        #expect(result != nil, "Replay should fire even for passthrough commands")
        let (decision, _) = parseResponse(result!)
        #expect(decision == "deny", "Should be a replay deny")
    }

    @Test func oldExecNotReplayed() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        // Insert exec event, then backdate it to 10 minutes ago via raw SQL.
        // recordTokenEvent always uses Date() internally, so we must update after insert.
        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        let oldTimestamp = Date().addingTimeInterval(-600).timeIntervalSince1970
        db.executeRawSQL("UPDATE token_events SET timestamp = \(oldTimestamp) WHERE command = 'swift test'")
        db.executeRawSQL("UPDATE commands SET timestamp = \(oldTimestamp) WHERE command = 'swift test'")

        setDirMtime(dir, to: Date().addingTimeInterval(-700))

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )

        #expect(result == nil, "Old exec (>5min) should not be replayed")
    }

    @Test func replayRecordsInterceptEvent() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        let sid = db.createSession(projectRoot: dir)
        insertExecEvent(db: db, command: "swift test", projectRoot: dir)
        setDirMtime(dir, to: Date().addingTimeInterval(-60))

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: sid,
            eventName: "PreToolUse",
            db: db
        )

        #expect(result != nil, "Should replay")

        // Flush async writes
        Thread.sleep(forTimeInterval: 0.1)

        // Check that a command_replay event was recorded
        let features = db.tokenStatsByFeature(projectRoot: dir)
        let replay = features.first { $0.feature == "command_replay" }
        #expect(replay != nil, "Should have recorded a command_replay event")
        #expect(replay?.eventCount == 1, "Should have exactly 1 replay event")
    }

    @Test func replayDenyMessageContainsOutputPreview() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        insertExecEvent(db: db, command: "cargo test", projectRoot: dir,
                        outputPreview: "All 42 tests passed in 3.2s")
        setDirMtime(dir, to: Date().addingTimeInterval(-60))

        let result = HookRouter.checkCommandReplay(
            command: "cargo test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )

        #expect(result != nil)
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains("All 42 tests passed") == true,
                "Deny message should contain the output preview")
    }

    // MARK: - Project fingerprint (ProjectFingerprint-backed invalidation)

    @Test func nestedFileModificationInvalidatesReplay() throws {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        // Create a nested source file BEFORE the exec.
        let nested = dir + "/src"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        let file = nested + "/app.swift"
        try "let x = 1\n".write(toFile: file, atomically: true, encoding: .utf8)
        let before = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: file)

        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        // Now modify the nested file AFTER the exec. macOS does NOT bump the
        // root directory's mtime for a nested write — the old root-mtime
        // check would have missed this and replayed stale output.
        try "let x = 2\n".write(toFile: file, atomically: true, encoding: .utf8)
        let after = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes([.modificationDate: after], ofItemAtPath: file)

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )
        #expect(result == nil, "Nested source change must invalidate replay")
    }

    @Test func nestedFileCreationInvalidatesReplay() throws {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        // Create a brand new source file deep in the tree after the exec.
        try "let y = 1\n".write(toFile: dir + "/src/new.swift", atomically: true, encoding: .utf8)

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )
        #expect(result == nil, "Creating a source file must invalidate replay")
    }

    @Test func ignoredDirectoryChangesDoNotInvalidateReplay() throws {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        // Tracked file, frozen well before the exec.
        let src = dir + "/app.swift"
        try "let x = 1\n".write(toFile: src, atomically: true, encoding: .utf8)
        let frozen = Date().addingTimeInterval(-300)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: src)

        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        // Changes inside .git / node_modules / .build should NOT invalidate.
        for skip in [".git", "node_modules", ".build"] {
            let skipDir = dir + "/" + skip
            try FileManager.default.createDirectory(atPath: skipDir, withIntermediateDirectories: true)
            try "junk".write(toFile: skipDir + "/HEAD.swift", atomically: true, encoding: .utf8)
        }

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )
        #expect(result != nil, "Changes in ignored dirs must NOT invalidate replay")
    }

    @Test func noSourceChangesReplaysWithFreshFingerprint() throws {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        // A tracked source file frozen BEFORE the exec — fingerprint is old.
        let src = dir + "/app.swift"
        try "let x = 1\n".write(toFile: src, atomically: true, encoding: .utf8)
        let frozen = Date().addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: frozen], ofItemAtPath: src)

        insertExecEvent(db: db, command: "swift test", projectRoot: dir)

        let result = HookRouter.checkCommandReplay(
            command: "swift test",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse",
            db: db
        )
        #expect(result != nil, "No source changes since exec → replay should fire")
    }

    // MARK: - Replay eligibility hardening

    @Test func rejectsChaining() {
        #expect(HookRouter.isReplayable("swift test; rm -rf tmp") == false)
        #expect(HookRouter.isReplayable("swift test && echo done") == false)
        #expect(HookRouter.isReplayable("swift test || true") == false)
    }

    @Test func rejectsRedirection() {
        #expect(HookRouter.isReplayable("swift test > out.txt") == false)
        #expect(HookRouter.isReplayable("swift test 2> err.txt") == false)
        #expect(HookRouter.isReplayable("swift test < input") == false)
    }

    @Test func rejectsPipes() {
        #expect(HookRouter.isReplayable("swift test | tee log") == false)
        #expect(HookRouter.isReplayable("npm test | grep pass") == false)
    }

    @Test func rejectsEnvPrefix() {
        #expect(HookRouter.isReplayable("FOO=bar swift test") == false)
        #expect(HookRouter.isReplayable("RUST_BACKTRACE=1 cargo test") == false)
    }

    @Test func rejectsCdPrefix() {
        // `cd subdir && swift test` contains &&, which is rejected.
        // Separately, `cd` as the first token is not in the allowlist.
        #expect(HookRouter.isReplayable("cd subdir && swift test") == false)
        #expect(HookRouter.isReplayable("cd subdir") == false)
    }

    @Test func rejectsWatchFlags() {
        #expect(HookRouter.isReplayable("npm test -- --watch") == false)
        #expect(HookRouter.isReplayable("npx vitest --watch") == false)
        #expect(HookRouter.isReplayable("npx jest --watchAll") == false)
        #expect(HookRouter.isReplayable("cargo test --watch") == false)
    }

    @Test func rejectsSubshellsAndBackticks() {
        #expect(HookRouter.isReplayable("swift test $(echo hi)") == false)
        #expect(HookRouter.isReplayable("swift test `whoami`") == false)
    }

    @Test func rejectsBackgrounding() {
        #expect(HookRouter.isReplayable("swift test &") == false)
    }

    @Test func rejectsUnknownTrailingFlags() {
        // --debug / --interactive / -i / a path argument all change behavior
        // enough that replaying cached output is wrong.
        #expect(HookRouter.isReplayable("swift test --debug") == false)
        #expect(HookRouter.isReplayable("npm test --inspect") == false)
        #expect(HookRouter.isReplayable("cargo test -- --ignored") == false)
    }

    @Test func keepsCanonicalReplayCasesGreen() {
        #expect(HookRouter.isReplayable("swift test"))
        #expect(HookRouter.isReplayable("swift build"))
        #expect(HookRouter.isReplayable("npm test"))
        #expect(HookRouter.isReplayable("npx jest"))
        #expect(HookRouter.isReplayable("cargo test"))
        #expect(HookRouter.isReplayable("cargo build --release"))
        #expect(HookRouter.isReplayable("go test"))
        #expect(HookRouter.isReplayable("pytest"))
        #expect(HookRouter.isReplayable("tsc --noEmit"))
    }

    @Test func postToolUseNeverReplays() {
        // PostToolUse is handled at the top of HookRouter.handle() — always passthrough.
        // Verify via the full handle() path.
        let event: [String: Any] = [
            "tool_name": "Bash",
            "hook_event_name": "PostToolUse",
            "tool_input": ["command": "swift test"],
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "PostToolUse should always passthrough")
    }
}
