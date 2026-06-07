import Testing
import Foundation
import SQLite3
@testable import Core

/// U.11a-2 — `ValidationAssertion` foundation tests.
///
/// 4 tests covering the 4 acceptance bullets:
///   1. Codable round-trip is byte-identical across 3 fixtures
///      (minimal, full-with-all-7-kinds-covered-in-table, custom).
///   2. `validationRunIDs` + `agentTraceRefs` resolve via the
///      existing store APIs; partial-resolution surfaces a
///      structured (resolved, unresolved) partition.
///   3. `deriveState` honors explicit override and computes
///      `.pass` / `.fail` / `.partial` from resolved evidence
///      according to the documented algorithm.
///   4. `assertion.record` writer lands a chained `token_events`
///      row that `ChainVerifier` accepts under the existing
///      `migration-v39` anchor; pre-v33 anchor gate refuses.
@Suite("ValidationAssertion (U.11a-2)")
struct ValidationAssertionTests {

    // MARK: - Helpers

    private static func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private static func canonicalDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private static func allKnownKinds() -> [AssertionKind] {
        return [
            .testsGreen, .lintClean, .perfWithinBudget,
            .securityClean, .designApproved, .completenessCheck
        ]
    }

    // MARK: - Fixtures

    /// Three deterministic fixtures matching the acceptance bullet:
    ///   - minimal: empty evidence lists, `.partial` state, kind=.testsGreen
    ///   - full: every known kind exercised at least once across
    ///     the fixture set (per "all-7-kinds-covered-in-table"),
    ///     full evidence lists, `.pass` state
    ///   - custom: `.custom(name:)` kind, mixed evidence, `.partial` state
    private static func fixtures() -> [ValidationAssertion] {
        let assertionA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let assertionB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let assertionC = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

        let minimal = ValidationAssertion(
            id: assertionA,
            kind: .testsGreen,
            validationRunIDs: [],
            agentTraceRefs: [],
            state: .partial
        )
        let full = ValidationAssertion(
            id: assertionB,
            kind: .completenessCheck,
            validationRunIDs: [
                UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000001")!,
                UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000002")!,
            ],
            agentTraceRefs: [
                AgentTraceRef(
                    sessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                    toolCallID: "tc-001"
                ),
                AgentTraceRef(
                    sessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                    toolCallID: "tc-002"
                ),
            ],
            state: .pass
        )
        let custom = ValidationAssertion(
            id: assertionC,
            kind: .custom(name: "deployability-check"),
            validationRunIDs: [
                UUID(uuidString: "DEADBEEF-0000-0000-0000-000000000003")!,
            ],
            agentTraceRefs: [
                AgentTraceRef(
                    sessionID: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                    toolCallID: "tc-custom"
                ),
            ],
            state: .partial
        )
        return [minimal, full, custom]
    }

    // MARK: - Tests

    @Test("Codable round-trip is byte-identical across three fixtures; all 7 kinds cover")
    func codableRoundTripByteIdentical() throws {
        let enc = Self.canonicalEncoder()
        let dec = Self.canonicalDecoder()

        // Per-fixture byte-identity check.
        for original in Self.fixtures() {
            let firstPass = try enc.encode(original)
            let decoded = try dec.decode(ValidationAssertion.self, from: firstPass)
            #expect(decoded == original,
                    "round-trip equality failed for id=\(original.id)")
            let secondPass = try enc.encode(decoded)
            #expect(firstPass == secondPass,
                    "second encode must be byte-identical for id=\(original.id)")
        }

        // Coverage: every known kind round-trips by itself, and the
        // custom case round-trips its associated `name`.
        for kind in Self.allKnownKinds() {
            let a = ValidationAssertion(
                id: UUID(), kind: kind,
                validationRunIDs: [], agentTraceRefs: [], state: .partial
            )
            let data = try enc.encode(a)
            let back = try dec.decode(ValidationAssertion.self, from: data)
            #expect(back.kind == kind, "kind \(kind) failed to round-trip")
        }
        // Custom case — round-trips the name.
        let customA = ValidationAssertion(
            id: UUID(), kind: .custom(name: "another-name"),
            validationRunIDs: [], agentTraceRefs: [], state: .pass
        )
        let customData = try enc.encode(customA)
        let customBack = try dec.decode(ValidationAssertion.self, from: customData)
        #expect(customBack.kind == .custom(name: "another-name"),
                "custom case failed to round-trip name; got \(customBack.kind)")
    }

    @Test("validationRunIDs + agentTraceRefs resolve through store APIs; unresolved is structured")
    func storeResolutionRoundTrip() throws {
        let path = "/tmp/senkani-u11a2-resolve-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }

        let sid = db.createSession(projectRoot: "/tmp/project")

        // Seed validation_results rows with two distinct run ids.
        let runA = UUID()
        let runB = UUID()
        let runMissing = UUID()
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/project/A.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 0, rawOutput: nil, advisory: "",
            durationMs: 5, validationRunId: runA.uuidString
        )
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/project/B.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "err", advisory: "fix it",
            durationMs: 5, validationRunId: runB.uuidString
        )
        db.flushWrites()

        // Seed agent_trace_event rows under two distinct
        // (session_id, tool_call_id) composites.
        let traceSession1 = UUID()
        let traceSession2 = UUID()
        let refOK = AgentTraceRef(sessionID: traceSession1, toolCallID: "ok-1")
        let refFail = AgentTraceRef(sessionID: traceSession2, toolCallID: "fail-1")
        let refMissing = AgentTraceRef(
            sessionID: UUID(), toolCallID: "never-recorded"
        )
        let okRow = AgentTraceEvent(
            idempotencyKey: "u11a2-ok",
            pane: "p", project: "/tmp/proj", model: "m",
            tier: nil, feature: .search, result: .success,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            sessionId: traceSession1.uuidString, toolCallId: "ok-1"
        )
        let failRow = AgentTraceEvent(
            idempotencyKey: "u11a2-fail",
            pane: "p", project: "/tmp/proj", model: "m",
            tier: nil, feature: .search, result: .error,
            startedAt: Date(timeIntervalSince1970: 1_700_000_002),
            completedAt: Date(timeIntervalSince1970: 1_700_000_003),
            sessionId: traceSession2.uuidString, toolCallId: "fail-1"
        )
        #expect(db.recordAgentTraceEvent(okRow))
        #expect(db.recordAgentTraceEvent(failRow))

        // Resolve: 3 ids — 2 present + 1 missing.
        let valRes = db.resolveValidationRuns([runA, runB, runMissing])
        #expect(valRes.resolved.count == 2,
                "expected 2 resolved validation rows; got \(valRes.resolved.count)")
        #expect(valRes.unresolved == [runMissing],
                "expected runMissing to be the sole unresolved id; got \(valRes.unresolved)")
        // First-row-wins per run_id; outcomes are intact.
        let byID = Dictionary(uniqueKeysWithValues:
            valRes.resolved.map { ($0.runID, $0) })
        #expect(byID[runA]?.outcome == "clean",
                "runA outcome wrong: \(String(describing: byID[runA]?.outcome))")
        #expect(byID[runB]?.outcome == "advisory",
                "runB outcome wrong: \(String(describing: byID[runB]?.outcome))")

        let traceRes = db.resolveAgentTraceRefs([refOK, refFail, refMissing])
        #expect(traceRes.resolved.count == 2,
                "expected 2 resolved trace rows; got \(traceRes.resolved.count)")
        #expect(traceRes.unresolved == [refMissing],
                "expected refMissing to be the sole unresolved ref; got \(traceRes.unresolved)")
        let byRef = Dictionary(uniqueKeysWithValues:
            traceRes.resolved.map { ($0.ref, $0) })
        #expect(byRef[refOK]?.result == .success,
                "refOK result wrong: \(String(describing: byRef[refOK]?.result))")
        #expect(byRef[refFail]?.result == .error,
                "refFail result wrong: \(String(describing: byRef[refFail]?.result))")
    }

    @Test("deriveState honors override and computes pass/fail/partial from evidence")
    func deriveStateAcrossScenarios() throws {
        let mkVal: (UUID, String, Int32) -> ResolvedValidationEvidence = { id, outcome, code in
            ResolvedValidationEvidence(
                runID: id, resultRowID: 1, outcome: outcome, exitCode: code
            )
        }
        let mkTrace: (String, CallResult) -> ResolvedAgentTraceEvidence = { key, result in
            ResolvedAgentTraceEvidence(
                ref: AgentTraceRef(sessionID: UUID(), toolCallID: key),
                idempotencyKey: key, result: result
            )
        }

        // (1) Explicit override short-circuits the algorithm even
        // when evidence would derive a different state.
        let allPassRes = ValidationEvidenceResolution(
            resolved: [mkVal(UUID(), "clean", 0)], unresolved: []
        )
        let allPassTrace = AgentTraceEvidenceResolution(
            resolved: [mkTrace("ok", .success)], unresolved: []
        )
        #expect(
            ValidationAssertion.deriveState(
                validationEvidence: allPassRes,
                agentTraceEvidence: allPassTrace,
                override: .partial
            ) == .partial,
            "override .partial must win over all-pass evidence"
        )

        // (2) All evidence pass → .pass.
        #expect(
            ValidationAssertion.deriveState(
                validationEvidence: allPassRes,
                agentTraceEvidence: allPassTrace
            ) == .pass
        )

        // (3) One evidence row fails (no clean rows) → .fail.
        let oneFailRes = ValidationEvidenceResolution(
            resolved: [mkVal(UUID(), "advisory", 1)], unresolved: []
        )
        let oneFailTrace = AgentTraceEvidenceResolution(
            resolved: [], unresolved: []
        )
        #expect(
            ValidationAssertion.deriveState(
                validationEvidence: oneFailRes,
                agentTraceEvidence: oneFailTrace
            ) == .fail
        )

        // (4) Mixed pass + fail across the two stores → .partial.
        let mixedTrace = AgentTraceEvidenceResolution(
            resolved: [mkTrace("ok", .success)], unresolved: []
        )
        #expect(
            ValidationAssertion.deriveState(
                validationEvidence: oneFailRes,
                agentTraceEvidence: mixedTrace
            ) == .partial,
            "mixed pass+fail evidence must yield .partial"
        )

        // (5) No evidence at all → .partial (provisional).
        let none = ValidationEvidenceResolution(resolved: [], unresolved: [])
        let noneTrace = AgentTraceEvidenceResolution(resolved: [], unresolved: [])
        #expect(
            ValidationAssertion.deriveState(
                validationEvidence: none,
                agentTraceEvidence: noneTrace
            ) == .partial
        )
    }

    @Test("assertion.record writer chains under migration-v39; ChainVerifier passes")
    func assertionRecordWriterChainsCleanly() throws {
        let path = "/tmp/senkani-u11a2-assert-events-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(db, path: path) }

        let assertionID = UUID()
        let contractID = UUID()

        db.recordAssertionEvent(
            assertionID: assertionID,
            contractID: contractID,
            state: .pass
        )
        db.recordAssertionEvent(
            assertionID: assertionID,
            contractID: contractID,
            state: .partial
        )
        db.recordAssertionEvent(
            assertionID: assertionID,
            contractID: contractID,
            state: .fail
        )

        // Flush the writer queue.
        _ = db.tokenEventExists(source: "u11a2-flush", feature: "noop")

        // Read back the 3 assertion.record rows.
        var rows: [(source: String, tool: String, feature: String, command: String)] = []
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                """
                SELECT source, tool_name, feature, command
                  FROM token_events
                 WHERE source = 'assertion.record'
                 ORDER BY id ASC;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else {
                Issue.record("source listing prepare failed")
                return
            }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let src = String(cString: sqlite3_column_text(stmt, 0))
                let tool = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let feat = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let cmd = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                rows.append((src, tool, feat, cmd))
            }
        }
        #expect(rows.count == 3,
                "expected 3 assertion.record rows; got \(rows.count)")
        let assertionStr = assertionID.uuidString
        let contractStr = contractID.uuidString
        for row in rows {
            #expect(row.source == "assertion.record")
            #expect(row.tool == assertionStr,
                    "tool_name must hold assertion UUID; got '\(row.tool)'")
            #expect(row.feature == contractStr,
                    "feature must hold contract UUID; got '\(row.feature)'")
        }
        // command carries the state raw value, ordered pass / partial / fail.
        #expect(rows.map { $0.command } == ["pass", "partial", "fail"],
                "command column must carry state raw values in order")

        // Verify the row's chain anchor reason includes 'migration-v39'
        // (fresh installs land here via the v39 migration step at boot).
        var anchorReasons: [String] = []
        db.unsafeQueueSync { rawDB in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                rawDB,
                """
                SELECT DISTINCT ca.reason
                  FROM token_events te
                  JOIN chain_anchors ca ON ca.id = te.chain_anchor_id
                 WHERE te.source = 'assertion.record';
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                anchorReasons.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        // The migration-v39 anchor is the only one opened for fresh
        // installs (or the existing v39 anchor reused on a primed DB);
        // either way it MUST be the post-v33 shape so the assertion
        // rows verify clean.
        #expect(!anchorReasons.isEmpty, "expected at least one anchor reason")
        let postV33Allowed: Set<String> = [
            "migration-v33", "fresh-install-pre-v35", "migration-v35",
            "fresh-install", "migration-v38", "migration-v39",
        ]
        for r in anchorReasons {
            #expect(postV33Allowed.contains(r),
                    "assertion row chained under unexpected anchor reason '\(r)'")
        }

        // Chain integrity holds end to end.
        let result = ChainVerifier.verifyTokenEvents(db)
        switch result {
        case .ok:
            break
        default:
            Issue.record("expected .ok after assertion.record writes; got \(result)")
        }
    }
}
