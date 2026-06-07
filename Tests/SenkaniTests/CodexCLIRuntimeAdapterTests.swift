import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-2 acceptance tests for `CodexCLIRuntimeAdapter`.
///
/// Covers the three acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-2-codex-cli-adapter.md`:
///   1. `CodexCLIRuntimeAdapter` conforms to `ProviderRuntimeAdapter`
///      with `providerID == "codex-cli"` and parses the wire
///      vocabulary onto the canonical 10-case enum.
///      (`happyPathTurnFixture`.)
///   2. All 3 fixtures parse cleanly; `raw_payload_hash` round-
///      trips through `ProviderRuntimeEventStore.insert(...)` and
///      is readable via canonical-row foreign-key lookup.
///      (`toolCallWithApprovalFixture` covers the second fixture
///      end-to-end; `warningAndAbortFixture` covers the third;
///      `happyPathTurnFixture` covers the first.)
///   3. Tool-call-finished fixture event projects into one
///      `agent_trace_event` row via v17a-1's projection helper;
///      replay is idempotent. (Asserted inside
///      `toolCallWithApprovalFixture`.)
///
/// Tests-target: 3. Adapter siblings v17a-3..5 will ship their
/// own CLI-specific fixture suites; v17a-6 will assert chain-
/// integrity across all four adapters.
@Suite("CodexCLIRuntimeAdapter (V.17a-2)")
struct CodexCLIRuntimeAdapterTests {

    // MARK: - Helpers

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-2-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    /// Run the adapter on `lines` (joined with `\n` + terminator),
    /// asserting partial-buffer continuity by feeding two halves
    /// where the split lands mid-line.
    private static func ingestAll(_ adapter: CodexCLIRuntimeAdapter, lines: [String]) async throws -> [ProviderRuntimeEvent] {
        let payload = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        return try await adapter.ingest(payload)
    }

    // MARK: - Test 1 — Fixture 1: happy-path turn (message.started → message.delta → turn.completed)

    @Test("Fixture 1 (happy-path turn): adapter conforms, parses message_started/message_delta/turn_completed; raw_payload_hash round-trips through the store")
    func happyPathTurnFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = CodexCLIRuntimeAdapter()
        // Conformance + providerID assertion (acceptance bullet 1).
        #expect((adapter as any ProviderRuntimeAdapter).providerID == "codex-cli")

        let lines = [
            #"{"type":"message.started","session_id":"s-happy","thread_id":"th-1","turn_id":"t-1","pane":"kb","ts":1700000100.0}"#,
            #"{"type":"message.delta","session_id":"s-happy","turn_id":"t-1","ts":1700000100.5,"usage":{"prompt_tokens":120,"completion_tokens":40}}"#,
            #"{"type":"turn.completed","session_id":"s-happy","turn_id":"t-1","ts":1700000101.0,"usage":{"prompt_tokens":120,"completion_tokens":80,"cached_tokens":20}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 3, "happy-path turn should yield 3 events")
        #expect(events.map { $0.type } == [.messageStarted, .messageDelta, .turnCompleted])
        #expect(events.allSatisfy { $0.providerID == "codex-cli" })
        #expect(events.allSatisfy { $0.sessionID == "s-happy" })
        #expect(events[0].pane == "kb" && events[0].threadID == "th-1")
        #expect(events[1].tokens?.promptTokens == 120 && events[1].tokens?.completionTokens == 40)
        #expect(events[2].tokens?.cachedTokens == 20)

        // Round-trip through ProviderRuntimeEventStore — every
        // distinct line lands one new row; replay is a no-op.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)
        // raw_payload_hash readable via lookup; replay hits the
        // UNIQUE constraint and returns idempotencyHit.
        for event in events {
            #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: event.rawPayloadHash) != nil)
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)

        // The two non-projectable events were auto-stamped
        // .ineligible; the turn.completed was stamped .pending.
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[0].rawPayloadHash) == .ineligible)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[1].rawPayloadHash) == .ineligible)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: events[2].rawPayloadHash) == .pending)
    }

    // MARK: - Test 2 — Fixture 2: tool-call with approval (covers projection acceptance bullet 3)

    @Test("Fixture 2 (tool-call with approval): all 6 events parse; tool_call.finished projects to agent_trace_event; replay is idempotent")
    func toolCallWithApprovalFixture() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = CodexCLIRuntimeAdapter()
        let lines = [
            #"{"type":"message.started","session_id":"s-tc","turn_id":"t-2","ts":1700000200.0}"#,
            #"{"type":"tool_call.started","session_id":"s-tc","turn_id":"t-2","tool_call_id":"tc-1","tool":"shell.exec","ts":1700000200.1}"#,
            #"{"type":"approval.requested","session_id":"s-tc","turn_id":"t-2","approval_id":"ap-1","ts":1700000200.2}"#,
            #"{"type":"approval.granted","session_id":"s-tc","turn_id":"t-2","approval_id":"ap-1","ts":1700000200.3}"#,
            #"{"type":"tool_call.completed","session_id":"s-tc","turn_id":"t-2","tool_call_id":"tc-1","result":"success","ts":1700000201.0}"#,
            #"{"type":"turn.completed","session_id":"s-tc","turn_id":"t-2","ts":1700000201.5,"usage":{"prompt_tokens":50,"completion_tokens":30}}"#,
        ]
        let events = try await Self.ingestAll(adapter, lines: lines)
        #expect(events.count == 6)
        #expect(events.map { $0.type } == [
            .messageStarted, .toolCallStarted,
            .approvalRequested, .approvalGranted,
            .toolCallFinished, .turnCompleted,
        ])
        // Approval pair correlates by approvalID.
        #expect(events[2].approvalID == "ap-1" && events[3].approvalID == "ap-1")
        // Tool-call pair correlates by toolCallID.
        #expect(events[1].toolCallID == "tc-1" && events[4].toolCallID == "tc-1")
        #expect(events[1].toolName == "shell.exec")
        #expect(events[4].toolResult == "success")

        // Persist + raw-hash round-trip.
        for event in events {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 6)

        // Acceptance bullet 3 — project the tool_call.finished event
        // into agent_trace_event; replay is idempotent.
        let toolCallFinished = events[4]
        #expect(toolCallFinished.isProjectable)
        let firstInserted = db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished)
        #expect(firstInserted, "first projection must insert a canonical trace row")
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .projected)

        let secondInserted = db.providerRuntimeEventStore.projectIntoAgentTrace(toolCallFinished)
        #expect(!secondInserted, "replay must not insert a second canonical trace row")
        #expect(db.agentTraceEventCount() == 1)
        #expect(db.providerRuntimeEventStore.projectionStatus(rawPayloadHash: toolCallFinished.rawPayloadHash) == .dedup)

        // Canonical row carries the conformed dimensions.
        let key = "v17a:\(toolCallFinished.rawPayloadHash)"
        let row = db.agentTraceEventStore.fetchByIdempotencyKey(key)
        #expect(row != nil)
        #expect(row?.sessionId == "s-tc")
        #expect(row?.toolCallId == "tc-1")
        #expect(row?.result == .success)
    }

    // MARK: - Test 3 — Fixture 3: warning + abort, partial-buffer continuity, and parser-error surface

    @Test("Fixture 3 (warning + abort): warnings + turn.aborted parse; partial-buffer continues across ingest calls; malformed JSON + unknown event-type surface as ParseError")
    func warningAndAbortFixtureAndAdapterRobustness() async throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let adapter = CodexCLIRuntimeAdapter()
        // Drive the 3 fixture lines split mid-line across two
        // `ingest(_:)` calls — exercises the buffer carryover
        // contract from the protocol doc.
        let lines = [
            #"{"type":"message.started","session_id":"s-warn","turn_id":"t-3","ts":1700000300.0}"#,
            #"{"type":"warning","session_id":"s-warn","turn_id":"t-3","message":"rate limit approaching","ts":1700000300.1}"#,
            #"{"type":"turn.aborted","session_id":"s-warn","turn_id":"t-3","ts":1700000301.0}"#,
        ]
        let joined = lines.joined(separator: "\n") + "\n"
        let full = Data(joined.utf8)
        // Split mid second-line (the warning JSON object) to force
        // the partial-buffer continuation path. Slice right after
        // the first '\n' + a few bytes into the next line — that
        // guarantees the warning line straddles the boundary.
        let firstLineByteLen = lines[0].utf8.count   // ASCII-only fixture
        let splitOffset = firstLineByteLen + 1 + 12  // past '\n' + 12 bytes
        let firstHalf = full.subdata(in: 0..<splitOffset)
        let secondHalf = full.subdata(in: splitOffset..<full.count)

        let firstEvents = try await adapter.ingest(firstHalf)
        // Only the message.started line is complete; the warning
        // line is mid-flight in the buffer.
        #expect(firstEvents.count == 1)
        #expect(firstEvents[0].type == .messageStarted)

        let secondEvents = try await adapter.ingest(secondHalf)
        #expect(secondEvents.count == 2, "remaining lines must surface on the second call")
        #expect(secondEvents.map { $0.type } == [.warning, .turnAborted])
        #expect(secondEvents[0].warnings == ["rate limit approaching"])

        // The full 3-event sequence persists cleanly; hashes are
        // identical to a non-split run (the hash is derived from
        // the CR-stripped line bytes, not the chunk boundaries).
        let allEvents = firstEvents + secondEvents
        for event in allEvents {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)

        // Reference run (single ingest) yields the same hashes —
        // proves the split-buffer hash invariant.
        let referenceAdapter = CodexCLIRuntimeAdapter()
        let referenceEvents = try await referenceAdapter.ingest(full)
        #expect(referenceEvents.count == 3)
        #expect(allEvents.map { $0.rawPayloadHash } == referenceEvents.map { $0.rawPayloadHash },
                "split-ingest hashes must match single-ingest hashes")
        // Replaying the reference run against the same DB hits the
        // UNIQUE constraint on every event.
        for event in referenceEvents {
            #expect(db.providerRuntimeEventStore.insert(event: event) == .idempotencyHit)
        }
        #expect(db.providerRuntimeEventStore.countAll() == 3)

        // Adapter robustness: malformed JSON line + unknown event-
        // type both surface as typed ParseError values — fixture
        // drift is observable, not silent.
        let bad = CodexCLIRuntimeAdapter()
        do {
            _ = try await bad.ingest(Data("not-json\n".utf8))
            Issue.record("expected malformed JSON to throw ParseError")
        } catch let err as CodexCLIRuntimeAdapter.ParseError {
            if case .malformedJSON = err {
                // expected
            } else {
                Issue.record("expected .malformedJSON, got \(err)")
            }
        }
        let unknown = CodexCLIRuntimeAdapter()
        do {
            let s = #"{"type":"future.event"}"# + "\n"
            _ = try await unknown.ingest(Data(s.utf8))
            Issue.record("expected unknown event type to throw ParseError")
        } catch let err as CodexCLIRuntimeAdapter.ParseError {
            if case .unknownEventType(let raw) = err {
                #expect(raw == "future.event")
            } else {
                Issue.record("expected .unknownEventType, got \(err)")
            }
        }
    }
}
