import Testing
import Foundation
@testable import Core

/// Prove that every persistence path — `commands`, `token_events`,
/// `sandboxed_results` — runs the same redaction. A missing redaction in
/// any one store leaks secrets for 24 h (sandboxed results) or for the
/// lifetime of the session DB (token_events).
@Suite("PersistenceRedaction coverage")
struct PersistenceRedactionTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-persist-redact-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private func cleanupDB(_ path: String) {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path)
        try? fm.removeItem(atPath: path + "-wal")
        try? fm.removeItem(atPath: path + "-shm")
    }

    // MARK: - Unit: PersistenceRedaction helper

    @Test func redactsAnthropicKey() {
        let (out, n) = PersistenceRedaction.redact("X-API-Key: sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
        #expect(!(out ?? "").contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"))
        #expect(n >= 1)
    }

    @Test func redactsBearerHeader() {
        let (out, n) = PersistenceRedaction.redact("curl -H 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb' https://x")
        #expect(!(out ?? "").contains("eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb"))
        #expect(n >= 1)
    }

    @Test func passesThroughNilAndEmpty() {
        #expect(PersistenceRedaction.redactedString(nil) == nil)
        #expect(PersistenceRedaction.redactedString("") == "")
    }

    // MARK: - token_events.command

    @Test func tokenEventsCommandIsRedacted() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordTokenEvent(
            sessionId: sid,
            paneId: nil,
            projectRoot: "/tmp/proj",
            source: "mcp_tool",
            toolName: "exec",
            model: nil,
            inputTokens: 10, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "exec",
            command: "curl -H 'Authorization: Bearer sk-ant-api03-abcdefghijklmnopqrstuvwxyz' https://x"
        )

        // Flush async write
        _ = db.tokenStatsAllProjects()
        Thread.sleep(forTimeInterval: 0.1)

        let events = db.recentTokenEvents(projectRoot: "/tmp/proj", limit: 10)
        #expect(!events.isEmpty, "expected at least one token event")
        let cmd = events.first?.command ?? ""
        #expect(!cmd.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"),
                "token_events.command leaked an Anthropic key: \(cmd)")
    }

    @Test func tokenEventsCommandRedactsAWSKey() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordTokenEvent(
            sessionId: sid, paneId: nil, projectRoot: "/tmp/proj",
            source: "mcp_tool", toolName: "exec", model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "exec",
            command: "aws sts get-caller-identity --access-key AKIAIOSFODNN7EXAMPLE"
        )
        _ = db.tokenStatsAllProjects()
        Thread.sleep(forTimeInterval: 0.1)

        let events = db.recentTokenEvents(projectRoot: "/tmp/proj", limit: 10)
        let cmd = events.first?.command ?? ""
        #expect(!cmd.contains("AKIAIOSFODNN7EXAMPLE"),
                "token_events.command leaked an AWS access key ID: \(cmd)")
    }

    // MARK: - sandboxed_results.command / full_output

    @Test func sandboxedResultsRedactsFullOutput() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        let bigOutput = """
        Starting build...
        API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwxyz
        Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb
        github-token=ghp_abcdefghijklmnopqrstuvwxyz0123456789
        Build succeeded.
        """

        let resultId = db.storeSandboxedResult(sessionId: sid, command: "env | grep KEY", output: bigOutput)
        guard let retrieved = db.retrieveSandboxedResult(resultId: resultId) else {
            Issue.record("retrieve returned nil")
            return
        }
        let stored = retrieved.output
        #expect(!stored.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"),
                "sandboxed_results.full_output leaked Anthropic key: \(stored)")
        #expect(!stored.contains("eyJhbGciOiJIUzI1NiJ9.aaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbb"),
                "sandboxed_results.full_output leaked Bearer token")
        #expect(!stored.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
                "sandboxed_results.full_output leaked GitHub token")
    }

    @Test func sandboxedResultsRedactsCommand() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        let resultId = db.storeSandboxedResult(
            sessionId: sid,
            command: "curl -H 'Authorization: Bearer sk-ant-api03-abcdefghijklmnopqrstuvwxyz' https://api",
            output: "ok"
        )
        guard let retrieved = db.retrieveSandboxedResult(resultId: resultId) else {
            Issue.record("retrieve returned nil")
            return
        }
        #expect(!retrieved.command.contains("sk-ant-api03-abcdefghijklmnopqrstuvwxyz"),
                "sandboxed_results.command leaked Anthropic key")
    }

    // MARK: - CommandStore (regression — behavior preserved)

    @Test func commandStoreStillRedactsAfterRefactor() throws {
        let (db, path) = makeTempDB()
        defer { cleanupDB(path) }

        let sid = db.createSession(projectRoot: "/tmp/proj")
        db.recordCommand(
            sessionId: sid,
            toolName: "exec",
            command: "export GITHUB_TOKEN=ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            rawBytes: 1000, compressedBytes: 500,
            feature: "exec",
            outputPreview: "ok"
        )
        Thread.sleep(forTimeInterval: 0.1)

        let results = db.search(query: "export")
        for row in results {
            let cmd = row.command ?? ""
            #expect(!cmd.contains("ghp_abcdefghijklmnopqrstuvwxyz0123456789"),
                    "commands.command leaked GitHub token after refactor: \(cmd)")
        }
    }
}
