import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-5 acceptance tests for `OpenCodeRuntimeAdapter`.
///
/// Covers the three acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-5-opencode-adapter.md`:
///   1. Conforms to `ProviderRuntimeAdapter` with
///      `providerID == "opencode"`. (`happyPathTurnFixture`.)
///   2. All 3 fixtures parse cleanly into canonical events.
///   3. `raw_payload_hash` round-trips; tool-call-finished
///      projection is idempotent. (`toolCallWithApprovalFixture`.)
@Suite("OpenCodeRuntimeAdapter (V.17a-5)")
struct OpenCodeRuntimeAdapterTests {

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-5-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func ingestAll(_ adapter: OpenCodeRuntimeAdapter, lines: [String]) async throws -> [ProviderRuntimeEvent] {
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        return try await adapter.ingest(payload)
    }

    // MARK: - Test 1 — Fixture 1: happy-path turn

    @Test("Fixture 1 (happy-path turn): adapter conforms with providerID=\"opencode\"; message-start + message-chunk + turn-finish parse to messageStarted + messageDelta + turnCompleted; usage envelope (input/output/cached) propagates")
    func happyPathTurnFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = OpenCodeRuntimeAdapter()
        #expect((adapter as any ProviderRuntimeAdapter).providerID == "opencode")

        let lines = [
            #"{"kind":"message-start","sessionId":"s-happy","threadId":"th-1","turnId":"t-1","pane":"kb","ts":1700000100.0}"#,
            #"{"kind":"message-chunk","sessionId":"s-happy","turnId":"t-1","ts":1700000100.5,"usage":{"input":120,"output":40}}"#,
            #"{"kind":"turn-finish","sessionId":"s-happy","turnId":"t-1","ts":1700000101.0,"usage":{"input":120,"output":80,"cached":18}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 3)
        #expect(events.map { $0.type } == [.messageStarted, .messageDelta, .turnCompleted])
        #expect(events.allSatisfy { $0.providerID == "opencode" })
        #expect(events.allSatisfy { $0.sessionID == "s-happy" })

        #expect(events[1].tokens?.promptTokens == 120 && events[1].tokens?.completionTokens == 40)
        #expect(events[2].tokens?.cachedTokens == 18)

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        // Auto-stamp invariant.
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[0].rawPayloadHash) == .ineligible)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[2].rawPayloadHash) == .pending)
        // Replay → all idempotency hits.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)
    }

    // MARK: - Test 2 — Fixture 2: tool-call with approval (projection acceptance bullet 3)

    @Test("Fixture 2 (tool-call with approval): tool-start + permission-prompt + permission-grant + tool-end + turn-finish parse; tool-end projects to agent_trace_event, replay idempotent")
    func toolCallWithApprovalFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = OpenCodeRuntimeAdapter()
        let lines = [
            #"{"kind":"tool-start","sessionId":"s-tc","turnId":"t-2","ts":1700000200.0,"toolId":"tc-oc1","toolName":"bash"}"#,
            #"{"kind":"permission-prompt","sessionId":"s-tc","turnId":"t-2","ts":1700000200.1,"permissionId":"perm-oc1","toolId":"tc-oc1"}"#,
            #"{"kind":"permission-grant","sessionId":"s-tc","turnId":"t-2","ts":1700000200.2,"permissionId":"perm-oc1"}"#,
            #"{"kind":"tool-end","sessionId":"s-tc","turnId":"t-2","ts":1700000201.0,"toolId":"tc-oc1","outcome":"success"}"#,
            #"{"kind":"turn-finish","sessionId":"s-tc","turnId":"t-2","ts":1700000201.5,"usage":{"input":50,"output":30}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 5)
        #expect(events.map { $0.type } == [
            .toolCallStarted, .approvalRequested, .approvalGranted,
            .toolCallFinished, .turnCompleted,
        ])
        #expect(events[0].toolCallID == "tc-oc1" && events[0].toolName == "bash")
        #expect(events[1].approvalID == "perm-oc1" && events[1].toolCallID == "tc-oc1")
        #expect(events[2].approvalID == "perm-oc1")
        #expect(events[3].toolCallID == "tc-oc1" && events[3].toolResult == "success")

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 5)

        // Projection round-trip (acceptance bullet 3).
        let toolCallFinished = events[3]
        #expect(toolCallFinished.isProjectable)
        #expect(db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished))
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .projected)

        #expect(!db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished))
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .dedup)

        let row = db.agentTraceEventStore.fetchByIdempotencyKey("v17a:\(toolCallFinished.rawPayloadHash)")
        #expect(row != nil)
        #expect(row?.sessionId == "s-tc")
        #expect(row?.toolCallId == "tc-oc1")
        #expect(row?.result == .success)
    }

    // MARK: - Test 3 — Fixture 3: warning + abort + parser-error surface

    @Test("Fixture 3 (warning + abort): diagnostic + turn-abort parse to .warning + .turnAborted carrying their text in `warnings`; malformed JSON + unknown kind throw typed ParseError")
    func warningAndAbortFixtureAndRobustness() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = OpenCodeRuntimeAdapter()
        let lines = [
            #"{"kind":"diagnostic","sessionId":"s-warn","turnId":"t-3","ts":1700000300.0,"message":"approaching token budget"}"#,
            #"{"kind":"turn-abort","sessionId":"s-warn","turnId":"t-3","ts":1700000301.0,"reason":"user_interrupt"}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 2)
        #expect(events.map { $0.type } == [.warning, .turnAborted])
        #expect(events[0].warnings == ["approaching token budget"])
        #expect(events[1].warnings == ["user_interrupt"])

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 2)

        // Parser-error surface.
        let bad = OpenCodeRuntimeAdapter()
        do {
            _ = try await bad.ingest(Data("not-json\n".utf8))
            Issue.record("expected ParseError.malformedJSON")
        } catch let err as OpenCodeRuntimeAdapter.ParseError {
            if case .malformedJSON = err {} else { Issue.record("expected .malformedJSON, got \(err)") }
        }

        let unknown = OpenCodeRuntimeAdapter()
        do {
            let s = #"{"kind":"unknown-shape"}"# + "\n"
            _ = try await unknown.ingest(Data(s.utf8))
            Issue.record("expected ParseError.unknownEventKind")
        } catch let err as OpenCodeRuntimeAdapter.ParseError {
            if case .unknownEventKind(let raw) = err {
                #expect(raw == "unknown-shape")
            } else { Issue.record("expected .unknownEventKind, got \(err)") }
        }
    }
}
