import Testing
import Foundation
@testable import MCPServer
@testable import Core

/// Phase B-ii: per-connection feature-toggle overrides.
///
/// `MCPSession.$currentToggleOverrides` is a `@TaskLocal` driven by
/// `ToolRouter.dispatchTool` from each connection's `ConnectionContext`.
/// Two concurrent tool calls — same project root, distinct override maps —
/// must observe distinct effective toggles, and neither must mutate the
/// shared session's stored defaults.
@Suite("MCPSession Phase B-ii — per-connection toggle overrides")
struct PerConnectionOverrideTests {

    private func makeSession() -> MCPSession {
        MCPSession(
            projectRoot: "/tmp/senkani-override-\(UUID().uuidString)",
            filterEnabled: true,
            secretsEnabled: true,
            indexerEnabled: false,
            cacheEnabled: false,
            terseEnabled: false,
            injectionGuardEnabled: false
        )
    }

    /// No override → effective getter returns the session-wide default.
    @Test func effectiveGetterFallsBackToSessionDefault() async {
        let session = makeSession()
        let filter = await session.effectiveFilterEnabled
        let secrets = await session.effectiveSecretsEnabled
        let terse = await session.effectiveTerseEnabled
        #expect(filter == true)
        #expect(secrets == true)
        #expect(terse == false)
    }

    /// With an override on `currentToggleOverrides`, the effective getter
    /// returns the overridden value; the session's stored default is
    /// untouched.
    @Test func overrideShadowsDefaultWithoutMutating() async {
        let session = makeSession()
        let baseline = await session.filterEnabled  // sanity: default is true

        let overrides = MCPSession.ToggleOverrides(filter: false)
        await MCPSession.$currentToggleOverrides.withValue(overrides) {
            let observed = await session.effectiveFilterEnabled
            #expect(observed == false, "override must shadow default for this call")
        }

        // After the call, the actor's stored default is unchanged.
        let after = await session.filterEnabled
        #expect(after == baseline, "stored filterEnabled must not be mutated by overrides")
    }

    /// Two concurrent Tasks with different overrides on the SAME session
    /// must observe distinct effective values. The session's stored
    /// defaults must not drift.
    @Test func twoTasksObserveDistinctOverridesOnSameSession() async {
        let session = makeSession()

        async let aResult = MCPSession.$currentToggleOverrides.withValue(
            MCPSession.ToggleOverrides(filter: false, secrets: false, terse: true)
        ) {
            let f = await session.effectiveFilterEnabled
            let s = await session.effectiveSecretsEnabled
            let t = await session.effectiveTerseEnabled
            return (f, s, t)
        }

        async let bResult = MCPSession.$currentToggleOverrides.withValue(
            MCPSession.ToggleOverrides(filter: true, secrets: true, terse: false)
        ) {
            let f = await session.effectiveFilterEnabled
            let s = await session.effectiveSecretsEnabled
            let t = await session.effectiveTerseEnabled
            return (f, s, t)
        }

        let a = await aResult
        let b = await bResult

        #expect(a == (false, false, true), "task A's override map must apply throughout its body")
        #expect(b == (true, true, false), "task B's override map must apply throughout its body")

        // Underlying defaults unchanged.
        let storedFilter = await session.filterEnabled
        let storedSecrets = await session.secretsEnabled
        let storedTerse = await session.terseEnabled
        #expect(storedFilter == true)
        #expect(storedSecrets == true)
        #expect(storedTerse == false)
    }

    /// `ToggleOverrides` with a partial map (some fields nil) must fall
    /// back to the session default for the unset fields and use the
    /// override for the set ones.
    @Test func partialOverrideMixesWithDefaults() async {
        let session = makeSession()
        let partial = MCPSession.ToggleOverrides(filter: false)  // others nil
        await MCPSession.$currentToggleOverrides.withValue(partial) {
            let f = await session.effectiveFilterEnabled
            let s = await session.effectiveSecretsEnabled
            #expect(f == false, "filter override applied")
            #expect(s == true, "secrets default preserved when override is nil")
        }
    }
}

/// Phase B-ii: DB-column threading + queryable view.
///
/// `MCPSession.recordMetrics` plumbs the resolved connection ID into both
/// `commands` and `token_events`. The `commandsForConnection` and
/// `aggregateForProject(...,groupByConnection:)` query helpers reconstruct
/// per-connection vs aggregate views from the same rows.
@Suite("MCPSession Phase B-ii — DB connection_id threading + queryable view")
struct CommandsConnectionIdTests {

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-conn-id-test-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    /// `recordCommand(connectionId:)` writes the column; `commandsForConnection`
    /// reads it back. End-to-end check on the facade.
    @Test func recordCommandTagsConnectionIdAndQueryReadsItBack() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanup(path) }

        let sid = db.createSession(projectRoot: "/tmp/conn-id-\(UUID().uuidString)")
        let connId = "conn-\(UUID().uuidString)"

        db.recordCommand(
            sessionId: sid, toolName: "read", command: "/tmp/x.swift",
            rawBytes: 100, compressedBytes: 50,
            connectionId: connId
        )
        // Drain the async queue — recordCommand fires-and-forgets onto
        // SessionDatabase.queue. A queue.sync read flushes prior writes.
        _ = db.totalStats()

        let rows = db.commandsForConnection(connectionId: connId)
        #expect(rows.count == 1, "expected 1 row tagged with connection_id, got \(rows.count)")
        #expect(rows.first?.toolName == "read")
        #expect(rows.first?.command == "/tmp/x.swift")
    }

    /// `aggregateForProject(groupByConnection: true)` produces one bucket
    /// per distinct connection_id; `false` rolls everything up under "".
    @Test func aggregateForProjectGroupsByConnection() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanup(path) }

        let projectRoot = "/tmp/conn-agg-\(UUID().uuidString)"
        let sid = db.createSession(projectRoot: projectRoot)
        let connA = "conn-A-\(UUID().uuidString)"
        let connB = "conn-B-\(UUID().uuidString)"

        for _ in 0..<3 {
            db.recordCommand(
                sessionId: sid, toolName: "read", command: "a.swift",
                rawBytes: 100, compressedBytes: 50, connectionId: connA
            )
        }
        for _ in 0..<2 {
            db.recordCommand(
                sessionId: sid, toolName: "read", command: "b.swift",
                rawBytes: 200, compressedBytes: 100, connectionId: connB
            )
        }
        _ = db.totalStats()  // drain queue

        let grouped = db.aggregateForProject(projectRoot: projectRoot, groupByConnection: true)
        #expect(grouped.count == 2, "expected 2 connection buckets, got \(grouped.count): \(grouped.keys)")
        #expect(grouped[connA]?.commandCount == 3)
        #expect(grouped[connA]?.totalRawBytes == 300)
        #expect(grouped[connB]?.commandCount == 2)
        #expect(grouped[connB]?.totalRawBytes == 400)

        let rolled = db.aggregateForProject(projectRoot: projectRoot, groupByConnection: false)
        #expect(rolled.count == 1, "rolled-up view has one bucket")
        #expect(rolled[""]?.commandCount == 5)
        #expect(rolled[""]?.totalRawBytes == 700)
    }

    /// Chain-hash backward-compat: a fresh DB hits the lazy 'fresh-install'
    /// anchor with the v18-shape canonical (connection_id included). Rows
    /// written without a connection_id (column = NULL) still verify cleanly.
    @Test func chainStillVerifiesWithNullConnectionId() {
        let (db, path) = Self.makeTempDB()
        defer { Self.cleanup(path) }

        let sid = db.createSession(projectRoot: "/tmp/chain-\(UUID().uuidString)")
        db.recordCommand(sessionId: sid, toolName: "read", command: "x.swift", rawBytes: 100, compressedBytes: 50)
        db.recordCommand(sessionId: sid, toolName: "read", command: "y.swift", rawBytes: 200, compressedBytes: 100)
        _ = db.totalStats()

        let result = ChainVerifier.verifyCommands(db)
        if case .brokenAt(let table, let rowid, let expected, let actual) = result {
            Issue.record("chain broken at \(table) rowid=\(rowid)\nexpected: \(expected)\nactual:   \(actual)")
        }
    }
}
