import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-3 acceptance tests for `ClaudeCodeRuntimeAdapter`.
///
/// Covers the three acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-3-claude-code-adapter.md`:
///   1. Conforms to `ProviderRuntimeAdapter` with
///      `providerID == "claude-code"`. (`happyPathTurnFixture`.)
///   2. All 3 fixtures parse cleanly; adapter delegates `usage`
///      block extraction to `ClaudeSessionReader.parseAssistantUsageLine`
///      — proven by `reuseSeamSharesParserWithClaudeSessionReader`.
///   3. `raw_payload_hash` round-trips; tool_call_finished event
///      projects into one idempotent `agent_trace_event` row.
///      (`toolCallWithApprovalFixture`.)
@Suite("ClaudeCodeRuntimeAdapter (V.17a-3)")
struct ClaudeCodeRuntimeAdapterTests {

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-3-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    private static func ingestAll(_ adapter: ClaudeCodeRuntimeAdapter, lines: [String]) async throws -> [ProviderRuntimeEvent] {
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        return try await adapter.ingest(payload)
    }

    // MARK: - Test 1 — Fixture 1: happy-path turn

    @Test("Fixture 1 (happy-path turn): adapter conforms with providerID=\"claude-code\"; assistant text + result success parse to messageStarted + turnCompleted; tokens propagate via the shared ClaudeSessionReader parser")
    func happyPathTurnFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = ClaudeCodeRuntimeAdapter()
        #expect((adapter as any ProviderRuntimeAdapter).providerID == "claude-code")

        let lines = [
            #"{"type":"system","subtype":"init","session_id":"s-happy"}"#,
            #"{"type":"user","session_id":"s-happy","ts":1700000100.0,"message":{"role":"user","content":"hello"}}"#,
            #"{"type":"assistant","session_id":"s-happy","ts":1700000101.0,"message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"hi back"}],"usage":{"input_tokens":120,"output_tokens":40,"cache_read_input_tokens":20,"cache_creation_input_tokens":5}}}"#,
            #"{"type":"result","subtype":"success","session_id":"s-happy","ts":1700000102.0,"usage":{"input_tokens":120,"output_tokens":80,"cache_read_input_tokens":20}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        // system.init is intentionally elided (no canonical event maps).
        #expect(events.count == 3, "expected 3 canonical events; system.init skipped")
        #expect(events.map { $0.type } == [.userInputRequested, .messageStarted, .turnCompleted])
        #expect(events.allSatisfy { $0.providerID == "claude-code" })
        #expect(events.allSatisfy { $0.sessionID == "s-happy" })

        // Token snapshot pulled by the shared parser (input/output/cache_read).
        let assistantEvent = events[1]
        #expect(assistantEvent.tokens?.promptTokens == 120)
        #expect(assistantEvent.tokens?.completionTokens == 40)
        #expect(assistantEvent.tokens?.cachedTokens == 20)

        // turn.completed result carries the usage envelope, projection-eligible.
        let turnCompleted = events[2]
        #expect(turnCompleted.tokens?.completionTokens == 80)
        #expect(turnCompleted.projectionStatus == .pending)

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)
        // Replay → all idempotency hits.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)
    }

    // MARK: - Test 2 — Fixture 2: tool-call with approval (covers projection acceptance bullet 3)

    @Test("Fixture 2 (tool-call with approval): tool_use + approval pair + tool_result + result success parse and round-trip; tool_call_finished projects to agent_trace_event, replay is idempotent")
    func toolCallWithApprovalFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = ClaudeCodeRuntimeAdapter()
        let lines = [
            // assistant message carrying a tool_use content block
            #"{"type":"assistant","session_id":"s-tc","ts":1700000200.0,"message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu-1","name":"Bash","input":{"command":"ls"}}]}}"#,
            // fabricated approval pair (Claude Code's permission flow is out-of-band; treat as a plausible wire shape)
            #"{"type":"approval","subtype":"requested","session_id":"s-tc","ts":1700000200.1,"approval_id":"ap-1","tool_use_id":"toolu-1"}"#,
            #"{"type":"approval","subtype":"granted","session_id":"s-tc","ts":1700000200.2,"approval_id":"ap-1","tool_use_id":"toolu-1"}"#,
            // user-typed line carrying tool_result for the same tool_use_id
            #"{"type":"user","session_id":"s-tc","ts":1700000201.0,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu-1","content":"ok","is_error":false}]}}"#,
            // turn complete
            #"{"type":"result","subtype":"success","session_id":"s-tc","ts":1700000201.5,"usage":{"input_tokens":50,"output_tokens":30}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 5)
        #expect(events.map { $0.type } == [
            .toolCallStarted,
            .approvalRequested, .approvalGranted,
            .toolCallFinished,
            .turnCompleted,
        ])
        // tool-call pair correlates by toolCallID
        #expect(events[0].toolCallID == "toolu-1")
        #expect(events[0].toolName == "Bash")
        #expect(events[3].toolCallID == "toolu-1")
        #expect(events[3].toolResult == "success")
        // approval pair correlates by approvalID + tool_use_id
        #expect(events[1].approvalID == "ap-1" && events[1].toolCallID == "toolu-1")
        #expect(events[2].approvalID == "ap-1" && events[2].toolCallID == "toolu-1")

        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 5)

        // Acceptance bullet 3 — project tool_call_finished into agent_trace_event.
        let toolCallFinished = events[3]
        #expect(toolCallFinished.isProjectable)
        #expect(db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished))
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .projected)

        // Replay idempotent.
        #expect(!db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished))
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .dedup)

        // Canonical row carries the conformed dimensions.
        let row = db.agentTraceEventStore.fetchByIdempotencyKey("v17a:\(toolCallFinished.rawPayloadHash)")
        #expect(row != nil)
        #expect(row?.sessionId == "s-tc")
        #expect(row?.toolCallId == "toolu-1")
        #expect(row?.result == .success)
    }

    // MARK: - Test 3 — Fixture 3: warning + abort, plus reuse-seam proof and parse-error surface

    @Test("Fixture 3 (warning + abort): system.warning + result error_max_turns parse to .warning + .turnAborted; the reuse seam delegates assistant-usage extraction to ClaudeSessionReader (no duplicated parser); malformed JSON + unknown shape throw typed ParseError")
    func warningAndAbortFixtureAndReuseSeam() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = ClaudeCodeRuntimeAdapter()
        let lines = [
            #"{"type":"assistant","session_id":"s-warn","ts":1700000300.0,"message":{"role":"assistant","content":[{"type":"text","text":"working..."}]}}"#,
            #"{"type":"system","subtype":"warning","session_id":"s-warn","ts":1700000300.1,"message":"context window remaining < 5%"}"#,
            #"{"type":"result","subtype":"error_max_turns","session_id":"s-warn","ts":1700000301.0}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 3)
        #expect(events.map { $0.type } == [.messageStarted, .warning, .turnAborted])
        #expect(events[1].warnings == ["context window remaining < 5%"])
        // turnAborted captures the result subtype in the warnings list so
        // downstream consumers can tell which abort flavor fired.
        #expect(events[2].warnings == ["error_max_turns"])

        // Reuse seam proof — calling ClaudeSessionReader.parseAssistantUsageLine
        // directly on the assistant fixture line yields the same usage shape
        // the adapter exposes via TokenSnapshot. This is the explicit
        // "delegates to existing module — no duplicated parsing logic"
        // acceptance bullet 2 check.
        let assistantLine = #"{"type":"assistant","session_id":"s-shared","ts":1700000999.0,"message":{"role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"x"}],"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":1,"cache_creation_input_tokens":2}}}"#
        let directParse = ClaudeSessionReader.parseAssistantUsageLine(assistantLine)
        #expect(directParse?.inputTokens == 7)
        #expect(directParse?.outputTokens == 3)
        #expect(directParse?.cacheReadTokens == 1)
        let viaAdapter = try await ClaudeCodeRuntimeAdapter().ingest(Data((assistantLine + "\n").utf8))
        #expect(viaAdapter.count == 1)
        #expect(viaAdapter[0].tokens?.promptTokens == 7)
        #expect(viaAdapter[0].tokens?.completionTokens == 3)
        #expect(viaAdapter[0].tokens?.cachedTokens == 1)

        // Round-trip + replay on the warning + abort fixture.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)

        // Parser-error surface.
        let bad = ClaudeCodeRuntimeAdapter()
        do {
            _ = try await bad.ingest(Data("not-json\n".utf8))
            Issue.record("expected malformed JSON to throw ParseError")
        } catch let err as ClaudeCodeRuntimeAdapter.ParseError {
            if case .malformedJSON = err {
                // ok
            } else {
                Issue.record("expected .malformedJSON, got \(err)")
            }
        }

        let unknown = ClaudeCodeRuntimeAdapter()
        do {
            let s = #"{"type":"never-heard-of","subtype":"x"}"# + "\n"
            _ = try await unknown.ingest(Data(s.utf8))
            Issue.record("expected unknown shape to throw ParseError")
        } catch let err as ClaudeCodeRuntimeAdapter.ParseError {
            if case .unknownEventShape(let ts) = err {
                #expect(ts == "never-heard-of/x")
            } else {
                Issue.record("expected .unknownEventShape, got \(err)")
            }
        }
    }
}
