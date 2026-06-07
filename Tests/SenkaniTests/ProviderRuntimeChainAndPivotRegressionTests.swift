import Testing
import Foundation
import SQLite3
@testable import Core

/// Phase V.17a-6 — closing round of the V.17a decomposition.
///
/// Covers the two acceptance bullets from
/// `spec/autonomous/backlog/phase-v17a-6-chain-integrity-and-pivot-regression.md`:
///   1. Chain-integrity 100-row write storm: 100
///      `provider_runtime_event` rows write via
///      `ProviderRuntimeEventStore.insert`; post-write,
///      `ChainVerifier.verifyAll(...)` returns `.ok` (or
///      `.noChain` for tables with no writes) across every
///      chain-participating table — V.17a's new table did NOT
///      introduce a regression on any chain anchor.
///   2. V.2 pivot regression: existing `AgentTraceEventStore`
///      per-project / per-feature / per-result pivots stay
///      correct after a fixture run that projects N V.17a
///      `tool_call_finished` events into the canonical row.
///
/// **Accepted-risk note (build-abort note 2026-05-23 Q4 implicit
/// answer).** `provider_runtime_event` does NOT participate in
/// the T.5 audit chain — same posture as V.2's `agent_trace_event`
/// (which is derived from the chain-anchored `token_events`).
/// Tampering is detectable by re-deriving from the underlying CLI
/// session logs the adapter ingested. The accepted-risk is
/// documented in:
///   - `Sources/Core/Migrations.swift` v36 migration comment
///   - `Sources/Core/ProviderRuntime/ProviderRuntimeEvent.swift`
///     class-doc
///   - `Sources/Core/Stores/ProviderRuntimeEventStore.swift`
///     class-doc
///   - V.17a-1 close-round evidence
///   - This test file's class-doc.
///
/// **18-test reconciliation.** v17a-1 (4) + v17a-2 (3) + v17a-3
/// (3) + v17a-4 (3) + v17a-5 (3) + v17a-6 (2) = 18, matching the
/// V.17a parent `tests_target: 18` exactly.
@Suite("ProviderRuntime chain-integrity + V.2 pivot regression (V.17a-6)")
struct ProviderRuntimeChainAndPivotRegressionTests {

    private static func tempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-v17a-6-\(UUID().uuidString).sqlite"
        let db = SessionDatabase(path: path)
        return (db, path)
    }

    /// Build a synthetic `provider_runtime_event` whose hash is
    /// unique per `i` so the store's UNIQUE constraint admits all
    /// 100 rows.
    private static func makeStormEvent(i: Int, providerID: String = "codex-cli") -> ProviderRuntimeEvent {
        let isProjectable = (i % 5 == 0)  // ~20% tool_call_finished, rest messageDelta
        return ProviderRuntimeEvent(
            providerID: providerID,
            sessionID: "storm-session-\(i % 4)",  // 4 distinct sessions
            threadID: nil,
            turnID: "turn-\(i)",
            pane: "kb",
            type: isProjectable ? .toolCallFinished : .messageDelta,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
            tokens: ProviderRuntimeEvent.TokenSnapshot(
                promptTokens: 10 + i, completionTokens: 5 + i, cachedTokens: nil
            ),
            toolCallID: isProjectable ? "tc-storm-\(i)" : nil,
            toolName: isProjectable ? "shell.exec" : nil,
            toolResult: isProjectable ? "success" : nil,
            warnings: [],
            projectionStatus: isProjectable ? .pending : .ineligible,
            rawPayloadHash: "storm-\(i)-\(UUID().uuidString)"
        )
    }

    // MARK: - Test 1 — chain-integrity write storm

    @Test("100-row provider_runtime_event write storm: every row lands; ChainVerifier.verifyAll() returns .ok or .noChain across every chain-participating table — V.17a's table addition introduces no chain regression (accepted-risk per V.2 precedent; provider_runtime_event itself is NOT in the chain)")
    func chainIntegrityWriteStorm() throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Pre-storm: assert the chain is clean across every
        // participating table on a fresh DB (no chain yet —
        // .noChain on every table is the expected baseline).
        let preResults = ChainVerifier.verifyAll(db)
        for (table, result) in preResults {
            switch result {
            case .ok, .noChain:
                break  // expected
            case .brokenAt(let table, let rowid, let expected, let actual):
                Issue.record("pre-storm chain unexpectedly broken on \(table) rowid=\(rowid) expected=\(expected) actual=\(actual)")
            }
            _ = table
        }
        // Sanity: provider_runtime_event must NOT appear in the
        // verifier's key set (V.17a parent Q4 accepted-risk).
        #expect(!preResults.keys.contains("provider_runtime_event"),
                "provider_runtime_event must NOT participate in T.5 chain; got keys \(preResults.keys.sorted())")

        // Write 100 events via the v17a-1 store.
        for i in 0..<100 {
            let event = Self.makeStormEvent(i: i)
            let outcome = db.providerRuntimeEventStore.insert(event: event)
            #expect(outcome == .insertedRow, "row \(i) must insert; got \(outcome)")
        }
        #expect(db.providerRuntimeEventStore.countAll() == 100,
                "exactly 100 provider_runtime_event rows after storm")

        // Post-storm: chain still clean on every participating
        // table. V.17a's new table addition + 100 writes did NOT
        // introduce a regression on any chain anchor.
        let postResults = ChainVerifier.verifyAll(db)
        for (table, result) in postResults {
            switch result {
            case .ok, .noChain:
                break  // expected — V.17a writes don't touch any chained table
            case .brokenAt(let t, let rowid, let expected, let actual):
                Issue.record("post-storm chain broken on \(t) rowid=\(rowid) expected=\(expected) actual=\(actual)")
            }
            _ = table
        }
        #expect(!postResults.keys.contains("provider_runtime_event"),
                "provider_runtime_event must STILL NOT be in chain post-storm")
        // Key set must be identical pre/post (V.17a writes don't
        // grow the chain's table inventory).
        #expect(Set(preResults.keys) == Set(postResults.keys),
                "ChainVerifier key set must be invariant under V.17a writes")
    }

    // MARK: - Test 2 — V.2 pivot regression

    @Test("V.2 pivot regression: AgentTraceEventStore per-project / per-feature / per-result pivots stay correct after V.17a projects 20 tool_call_finished events into the canonical row (projection-derived rows bucket under their conformed dimensions — no leakage paths)")
    func v2PivotRegressionAfterV17aProjection() throws {
        let (db, path) = Self.tempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Seed baseline V.2 rows with known project/feature/result
        // shapes so the pivots produce reproducible buckets even
        // before V.17a projection.
        let baseStart = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<6 {
            let row = AgentTraceEvent(
                idempotencyKey: "baseline-\(i)",
                pane: "kb", project: "/proj/baseline", model: nil, tier: nil,
                feature: .search, result: .success,
                startedAt: baseStart, completedAt: baseStart.addingTimeInterval(0.1),
                latencyMs: 10, tokensIn: 100, tokensOut: 50, costCents: 1
            )
            db.recordAgentTraceEvent(row)
        }
        // Pre-projection pivot counts.
        let preProject = db.agentTraceEventStore.pivotByProject()
        let baselineProjectBucket = preProject.first(where: { $0.project == "/proj/baseline" })
        #expect(baselineProjectBucket?.eventCount == 6, "baseline project bucket")
        let preResult = db.agentTraceEventStore.pivotByResult()
        let baselineSuccessBucket = preResult.first(where: { $0.result == "success" })
        #expect(baselineSuccessBucket?.eventCount == 6, "baseline success bucket")

        // Project 20 V.17a tool_call_finished events into the
        // canonical row via the v17a-1 projection helper. The
        // canonical row's `project` and `feature` columns are NULL
        // for projected rows (the V.17a adapter doesn't set them
        // — that's a V.17b dashboard responsibility), and `result`
        // derives from the event's `toolResult`.
        for i in 0..<20 {
            let event = ProviderRuntimeEvent(
                providerID: "codex-cli",
                sessionID: "pivot-sess-\(i)",
                threadID: nil, turnID: "pivot-turn-\(i)", pane: "kb",
                type: .toolCallFinished,
                observedAt: baseStart.addingTimeInterval(Double(i)),
                tokens: ProviderRuntimeEvent.TokenSnapshot(promptTokens: 10, completionTokens: 5, cachedTokens: nil),
                toolCallID: "tc-pivot-\(i)",
                toolName: "shell.exec",
                toolResult: "success",
                warnings: [],
                projectionStatus: .pending,
                rawPayloadHash: "pivot-\(i)-\(UUID().uuidString)"
            )
            #expect(db.providerRuntimeEventStore.insert(event: event) == .insertedRow)
            #expect(db.providerRuntimeEventStore.projectIntoAgentTrace(event),
                    "projection \(i) must land a canonical row")
        }
        #expect(db.agentTraceEventCount() == 26, "6 baseline + 20 projected = 26 canonical rows")

        // Post-projection pivots: baseline buckets unchanged;
        // projected rows bucket under NULL project / NULL feature
        // / 'success' result.
        let postProject = db.agentTraceEventStore.pivotByProject()
        let postBaselineProject = postProject.first(where: { $0.project == "/proj/baseline" })
        #expect(postBaselineProject?.eventCount == 6,
                "baseline project bucket must NOT absorb V.17a-projected rows")
        let postProjectedNullBucket = postProject.first(where: { $0.project == "" })
        #expect(postProjectedNullBucket?.eventCount == 20,
                "V.17a-projected rows bucket under NULL project as a distinct bucket")

        let postFeature = db.agentTraceEventStore.pivotByFeature()
        let baselineFeatureBucket = postFeature.first(where: { $0.feature == "search" })
        #expect(baselineFeatureBucket?.eventCount == 6,
                "baseline feature bucket must NOT absorb V.17a-projected rows")
        let nullFeatureBucket = postFeature.first(where: { $0.feature == "" })
        #expect(nullFeatureBucket?.eventCount == 20,
                "V.17a-projected rows bucket under NULL feature as a distinct bucket")

        let postResult = db.agentTraceEventStore.pivotByResult()
        let postSuccessBucket = postResult.first(where: { $0.result == "success" })
        // 6 baseline successes + 20 projected successes = 26
        #expect(postSuccessBucket?.eventCount == 26,
                "result=success bucket aggregates baseline + projected; no other-result buckets leaked")
        // Confirm no spurious result buckets emerged from
        // projection — derived `success` is the only result
        // string that should be present.
        let resultStrings = Set(postResult.map { $0.result })
        #expect(resultStrings == ["success"],
                "only 'success' result bucket should exist post-projection; got \(resultStrings.sorted())")
    }
}
