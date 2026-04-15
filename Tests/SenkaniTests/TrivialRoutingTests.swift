import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-trivial-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func makeTempDir(files: [String] = []) -> String {
    let path = "/tmp/senkani-trivial-dir-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    for file in files {
        let filePath = path + "/" + file
        let dir = (filePath as NSString).deletingLastPathComponent
        if dir != path {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        FileManager.default.createFile(atPath: filePath, contents: Data("// \(file)".utf8))
    }
    return path
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

@Suite("HookRouter — Trivial Routing")
struct TrivialRoutingTests {

    @Test func pwdReturnsProjectRoot() {
        let result = HookRouter.checkTrivialRouting(
            command: "pwd",
            projectRoot: "/tmp/myproject",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil, "pwd should be trivially routed")
        let (decision, reason) = parseResponse(result!)
        #expect(decision == "deny")
        #expect(reason?.contains("/tmp/myproject") == true, "Should contain the project root")
    }

    @Test func pwdFallsBackWithNoRoot() {
        let result = HookRouter.checkTrivialRouting(
            command: "pwd",
            projectRoot: nil,
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil, "pwd should still work without projectRoot")
        let (decision, _) = parseResponse(result!)
        #expect(decision == "deny")
    }

    @Test func whoamiReturnsUsername() {
        let result = HookRouter.checkTrivialRouting(
            command: "whoami",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil)
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains(NSUserName()) == true, "Should contain the current username")
    }

    @Test func hostnameReturnsHost() {
        let result = HookRouter.checkTrivialRouting(
            command: "hostname",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil)
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains(ProcessInfo.processInfo.hostName) == true)
    }

    @Test func dateReturnsSomething() {
        let result = HookRouter.checkTrivialRouting(
            command: "date",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil, "date should be trivially routed")
        let (decision, reason) = parseResponse(result!)
        #expect(decision == "deny")
        #expect(reason != nil && !reason!.isEmpty)
    }

    @Test func echoReturnsText() {
        let result = HookRouter.checkTrivialRouting(
            command: "echo hello world",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil)
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains("hello world") == true)
    }

    @Test func echoStripsQuotes() {
        let doubleQuoted = HookRouter.checkTrivialRouting(
            command: "echo \"hello\"",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )
        let singleQuoted = HookRouter.checkTrivialRouting(
            command: "echo 'hello'",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        let (_, reason1) = parseResponse(doubleQuoted!)
        let (_, reason2) = parseResponse(singleQuoted!)
        #expect(reason1?.contains("hello") == true)
        #expect(reason2?.contains("hello") == true)
    }

    @Test func echoWithVariablePassesThrough() {
        let result = HookRouter.checkTrivialRouting(
            command: "echo $HOME",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result == nil, "echo with $ should pass through")
    }

    @Test func lsListsDirectory() {
        let dir = makeTempDir(files: ["main.swift", "Package.swift", "README.md"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = HookRouter.checkTrivialRouting(
            command: "ls",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil, "ls should be trivially routed")
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains("main.swift") == true)
        #expect(reason?.contains("Package.swift") == true)
        #expect(reason?.contains("README.md") == true)
    }

    @Test func lsHidesDotfiles() {
        let dir = makeTempDir(files: [".hidden", "visible.txt"])
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let result = HookRouter.checkTrivialRouting(
            command: "ls",
            projectRoot: dir,
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result != nil)
        let (_, reason) = parseResponse(result!)
        #expect(reason?.contains("visible.txt") == true)
        #expect(reason?.contains(".hidden") != true, "Should hide dotfiles")
    }

    @Test func lsWithFlagsPassesThrough() {
        let result = HookRouter.checkTrivialRouting(
            command: "ls -la",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result == nil, "ls with flags should pass through")
    }

    @Test func pipePassesThrough() {
        let result = HookRouter.checkTrivialRouting(
            command: "pwd | cat",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result == nil, "Commands with pipes should pass through")
    }

    @Test func semicolonPassesThrough() {
        let result = HookRouter.checkTrivialRouting(
            command: "pwd; ls",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result == nil, "Commands with semicolons should pass through")
    }

    @Test func recordsInterceptEvent() {
        let (db, dbPath) = makeTempDB()
        let dir = makeTempDir()
        defer { cleanupDB(dbPath); try? FileManager.default.removeItem(atPath: dir) }

        let sid = db.createSession(projectRoot: dir)

        let result = HookRouter.checkTrivialRouting(
            command: "pwd",
            projectRoot: dir,
            sessionId: sid,
            eventName: "PreToolUse",
            db: db
        )

        #expect(result != nil)

        // Flush async writes
        Thread.sleep(forTimeInterval: 0.1)

        let features = db.tokenStatsByFeature(projectRoot: dir)
        let trivial = features.first { $0.feature == "trivial_routing" }
        #expect(trivial != nil, "Should have recorded a trivial_routing event")
        #expect(trivial?.eventCount == 1)
    }

    @Test func nonTrivialPassesThrough() {
        let result = HookRouter.checkTrivialRouting(
            command: "cat foo.txt",
            projectRoot: "/tmp",
            sessionId: nil,
            eventName: "PreToolUse"
        )

        #expect(result == nil, "cat is not a trivial command")
    }
}
