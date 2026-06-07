import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-4 acceptance tests for `GeminiCLIRuntimeAdapter`.
///
/// Covers the three acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-4-gemini-cli-adapter.md`:
///   1. Conforms to `ProviderRuntimeAdapter` with
///      `providerID == "gemini-cli"`. (`happyPathTurnFixture`.)
///   2. All 3 fixtures parse cleanly into canonical events.
///      (`happyPathTurnFixture` + `toolCallWithApprovalFixture`
///      + `warningAndAbortFixtureAndRobustness`.)
///   3. `raw_payload_hash` round-trips; tool-call-finished
///      projection is idempotent. (`toolCallWithApprovalFixture`.)
@Suite("GeminiCLIRuntimeAdapter (V.17a-4)")
struct GeminiCLIRuntimeAdapterTests {

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-4-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func ingestAll(_ adapter: GeminiCLIRuntimeAdapter, lines: [String]) async throws -> [ProviderRuntimeEvent] {
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        return try await adapter.ingest(payload)
    }

    // MARK: - Test 1 — Fixture 1: happy-path turn

    @Test("Fixture 1 (happy-path turn): adapter conforms with providerID=\"gemini-cli\"; content_start + content_delta + turn_end parse to messageStarted + messageDelta + turnCompleted with usage propagating from Gemini's promptTokenCount/candidatesTokenCount/cachedContentTokenCount envelope")
    func happyPathTurnFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = GeminiCLIRuntimeAdapter()
        #expect((adapter as any ProviderRuntimeAdapter).providerID == "gemini-cli")

        let lines = [
            #"{"event_type":"content_start","sessionId":"s-happy","threadId":"th-1","turnId":"t-1","pane":"kb","ts":1700000100.0}"#,
            #"{"event_type":"content_delta","sessionId":"s-happy","turnId":"t-1","ts":1700000100.5,"usage":{"promptTokenCount":120,"candidatesTokenCount":40}}"#,
            #"{"event_type":"turn_end","sessionId":"s-happy","turnId":"t-1","ts":1700000101.0,"usage":{"promptTokenCount":120,"candidatesTokenCount":80,"cachedContentTokenCount":15}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 3)
        #expect(events.map { $0.type } == [.messageStarted, .messageDelta, .turnCompleted])
        #expect(events.allSatisfy { $0.providerID == "gemini-cli" })
        #expect(events.allSatisfy { $0.sessionID == "s-happy" })

        // Token snapshot from Gemini's promptTokenCount/candidatesTokenCount.
        #expect(events[1].tokens?.promptTokens == 120 && events[1].tokens?.completionTokens == 40)
        #expect(events[2].tokens?.cachedTokens == 15)

        // Auto-stamp: messageStarted/messageDelta → .ineligible; turn_end → .pending.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[0].rawPayloadHash) == .ineligible)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[1].rawPayloadHash) == .ineligible)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[2].rawPayloadHash) == .pending)

        // Replay → all idempotency hits.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)
    }

    // MARK: - Test 2 — Fixture 2: tool-call with approval

    @Test("Fixture 2 (tool-call with approval): tool_invoke + permission_request + permission_response(granted=true) + tool_result + turn_end parse; tool_result projects to agent_trace_event, replay is idempotent")
    func toolCallWithApprovalFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = GeminiCLIRuntimeAdapter()
        let lines = [
            #"{"event_type":"tool_invoke","sessionId":"s-tc","turnId":"t-2","ts":1700000200.0,"toolCallId":"tc-g1","toolName":"run_shell_command"}"#,
            #"{"event_type":"permission_request","sessionId":"s-tc","turnId":"t-2","ts":1700000200.1,"approvalId":"ap-g1","toolCallId":"tc-g1"}"#,
            #"{"event_type":"permission_response","sessionId":"s-tc","turnId":"t-2","ts":1700000200.2,"approvalId":"ap-g1","granted":true}"#,
            #"{"event_type":"tool_result","sessionId":"s-tc","turnId":"t-2","ts":1700000201.0,"toolCallId":"tc-g1","status":"success"}"#,
            #"{"event_type":"turn_end","sessionId":"s-tc","turnId":"t-2","ts":1700000201.5,"usage":{"promptTokenCount":50,"candidatesTokenCount":30}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 5)
        #expect(events.map { $0.type } == [
            .toolCallStarted, .approvalRequested, .approvalGranted,
            .toolCallFinished, .turnCompleted,
        ])
        #expect(events[0].toolCallID == "tc-g1" && events[0].toolName == "run_shell_command")
        #expect(events[1].approvalID == "ap-g1" && events[1].toolCallID == "tc-g1")
        #expect(events[2].approvalID == "ap-g1")
        #expect(events[3].toolCallID == "tc-g1" && events[3].toolResult == "success")

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 5)

        // Projection round-trip — acceptance bullet 3.
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
        #expect(row?.toolCallId == "tc-g1")
        #expect(row?.result == .success)
    }

    // MARK: - Test 3 — Fixture 3: warning + abort + parse-error surface

    @Test("Fixture 3 (warning + abort): warning + turn_cancelled parse to .warning + .turnAborted (reason carried in warnings list); malformed JSON + unknown event-type throw typed ParseError; permission_response(granted=false) maps to .turnAborted as the least-lossy denial mapping")
    func warningAndAbortFixtureAndRobustness() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = GeminiCLIRuntimeAdapter()
        let lines = [
            #"{"event_type":"warning","sessionId":"s-warn","turnId":"t-3","ts":1700000300.0,"message":"safety filter triggered"}"#,
            #"{"event_type":"turn_cancelled","sessionId":"s-warn","turnId":"t-3","ts":1700000301.0,"reason":"user_interrupt"}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 2)
        #expect(events.map { $0.type } == [.warning, .turnAborted])
        #expect(events[0].warnings == ["safety filter triggered"])
        #expect(events[1].warnings == ["user_interrupt"])

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 2)

        // permission_response with granted=false maps to .turnAborted
        // (least-lossy denial mapping — canonical enum has no
        // approvalDenied case today).
        let denialAdapter = GeminiCLIRuntimeAdapter()
        let denyLines = [
            #"{"event_type":"permission_response","sessionId":"s-deny","turnId":"t-d","ts":1700000400.0,"approvalId":"ap-d1","granted":false}"#,
        ]
        let denyEvents = try await Self.ingestAll(denialAdapter, lines: denyLines)
        #expect(denyEvents.count == 1)
        #expect(denyEvents[0].type == .turnAborted)
        #expect(denyEvents[0].approvalID == "ap-d1")

        // Parser-error surface.
        let bad = GeminiCLIRuntimeAdapter()
        do {
            _ = try await bad.ingest(Data("not-json\n".utf8))
            Issue.record("expected ParseError.malformedJSON")
        } catch let err as GeminiCLIRuntimeAdapter.ParseError {
            if case .malformedJSON = err {} else { Issue.record("expected .malformedJSON, got \(err)") }
        }

        let unknown = GeminiCLIRuntimeAdapter()
        do {
            let s = #"{"event_type":"function_call.unknown"}"# + "\n"
            _ = try await unknown.ingest(Data(s.utf8))
            Issue.record("expected ParseError.unknownEventType")
        } catch let err as GeminiCLIRuntimeAdapter.ParseError {
            if case .unknownEventType(let raw) = err {
                #expect(raw == "function_call.unknown")
            } else { Issue.record("expected .unknownEventType, got \(err)") }
        }
    }
}
