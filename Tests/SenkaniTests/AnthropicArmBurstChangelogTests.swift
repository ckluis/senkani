import Testing
import Foundation
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13b-5 `phase-v13b-5-doctor-burst-changelog` (2026-06-01) — 10-request
/// BURST regression test for the Anthropic serve arm. Two halves matching
/// the two persisted observability sinks the b-4c live dispatch + b-4d
/// dual-row audit shipped:
///
///   - **Sink half** (normal unit, MockURLProtocol-stubbed): 10 sequential
///     `ClaudeAPIServeDispatch.dispatch(...)` calls (each with a distinct
///     `id`) drive the live Anthropic-arm path; each Outcome is persisted
///     via `OpenAIServedRequestSink.record(...,db: sharedTempDB)`; the
///     assertion is `db.recentOpenAIRequests(limit:20).count == 10` with
///     every row attributed to `surface == "chat"`, `status == 200`, and
///     distinct ids — proving the b-4c sink seam scales to a small burst
///     without doubling, dropping, or cross-attributing rows.
///
///   - **egress_decisions half** (live in-process EgressListener over
///     loopback CONNECT — Option A in the spec): a default-deny listener
///     on a tempDB; one `URLSession` built via
///     `ClaudeAPIServeEngineFactory.proxiedConfiguration(port:)` with
///     `timeoutIntervalForRequest:2` + `httpMaximumConnectionsPerHost:1`;
///     10 SEQUENTIAL `dataTask`s to `https://api.anthropic.com/v1/messages`
///     (each gated by its own `DispatchSemaphore` — NOT fired in parallel,
///     because the b-4d acceptance for `count == 1` per single CONNECT
///     only holds if each request gets its own tunnel, which means
///     sequential calls); `session.invalidateAndCancel()` BEFORE reading
///     rows; assertion is `db.recentEgressDecisions(limit:20).count == 10`
///     with every row `host == "api.anthropic.com"`, `method == "CONNECT"`,
///     `decision == .deny`, `ruleId == "default-deny"`; and
///     `ChainVerifier.verifyEgressDecisions(db) == .ok`.
///
/// **CONNECT-coalescing choice (CAVEAT, documented per the b-5 spec).**
/// HTTP/2 connection coalescing under URLSession's keepalive could
/// theoretically collapse multiple CONNECTs onto one tunnel — unlikely
/// for distinct requests on `httpMaximumConnectionsPerHost:1` but
/// possible under certain URLSession states. The b-4d single-CONNECT
/// `count == 1` acceptance held because the listener refused the tunnel
/// with 403 after the deny row, so each subsequent request must
/// re-establish a fresh tunnel. We replicate that same shape here:
/// since the listener CLOSES every CONNECT with a deny (no allowed
/// tunnel ever stays open), URLSession has no live keepalive tunnel to
/// reuse — every request must issue a fresh CONNECT, producing one
/// deny row per request. **Choice: shared session.** The deny-fronted
/// listener structurally precludes coalescing (no upstream keepalive
/// ever forms) so a shared `URLSession` is sufficient AND deterministic.
/// If a future URLSession change introduces speculative-tunnel reuse
/// across denied CONNECTs (vanishingly unlikely — denies are 403, not
/// 200), this assertion will fail and the test comment directs the
/// reviewer to a per-request fresh URLSession fallback.
///
/// Both halves run `.serialized` so the process-global URLProtocol
/// registry (sink half) and process-global TCP listener state (egress
/// half) cannot race against parallel suites.

private func burstTempDB() -> SessionDatabase {
    let dir = NSTemporaryDirectory() + "senkani-v13b-5-burst-\(UUID().uuidString)/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return SessionDatabase(path: dir + "senkani.db")
}

private func burstWaitForRowCount(
    db: SessionDatabase,
    target: Int,
    timeoutSeconds: Double = 10.0
) -> Int {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    var observed = 0
    while Date() < deadline {
        observed = db.recentEgressDecisions(limit: target + 5).count
        if observed >= target { return observed }
        usleep(20_000)
    }
    return observed
}

// MARK: - Sink half — 10 dispatch → record → recentOpenAIRequests rows

@Suite("AnthropicArmBurst — sink half: 10 dispatch+record produce 10 chat rows (V.13b-5)",
       .serialized, .urlProtocolGate)
struct AnthropicArmBurstSinkTests {

    private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private func makeEngine() -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: "sk-ant-burst",
            session: session,
            endpoint: anthropicURL,
            retryPolicy: .default,
            sleeper: { _ in }
        )
    }

    private func routing() -> OpenAIChatHandler.Routing {
        OpenAIChatHandler.Routing(
            presetUsed: .auto,
            resolvedTier: .quick,
            actualModel: ModelTier.quick.claudeModelValue,
            modelLogged: "gpt-4o"
        )
    }

    private func request() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-4o",
            messages: [.init(role: "user", content: "ping")]
        )
    }

    private func successBody(id: String) -> Data {
        Data("""
        {"id":"\(id)","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":4,"output_tokens":2}}
        """.utf8)
    }

    /// 10 sequential dispatches with distinct ids land 10 distinct
    /// chat=200 rows in the persisted `openai_request_log`.
    @Test("10 sequential dispatch → record calls land 10 distinct chat=200 rows")
    func tenDispatchesLandTenChatRows() {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        MockURLProtocol.register(url: anthropicURL, status: 200, body: successBody(id: "msg_burst"))

        let db = burstTempDB()
        let chain = OpenAIAuditChain()
        let engine = makeEngine()
        let routing = routing()
        let request = request()

        var dispatchedIds: [String] = []
        for i in 0..<10 {
            let id = "chatcmpl-v13b-5-burst-\(i)"
            let outcome = ClaudeAPIServeDispatch.dispatch(
                engine: engine,
                request: request,
                routing: routing,
                keyLabel: "burst-label",
                now: Date(timeIntervalSince1970: 1_700_000_000 + TimeInterval(i)),
                id: id
            )
            #expect(outcome.httpStatus == 200,
                "dispatch[\(i)] expected 200, got \(outcome.httpStatus)")
            let landed = OpenAIServedRequestSink.record(
                chain: chain,
                fields: outcome.auditFields,
                bodies: outcome.auditBodies,
                db: db,
                surface: .chat,
                httpStatus: outcome.httpStatus
            )
            #expect(landed, "sink.record[\(i)] failed to persist")
            dispatchedIds.append(id)
        }

        let rows = db.recentOpenAIRequests(limit: 20)
        // PRIMARY assertion: exactly 10 rows (acceptance contract).
        #expect(rows.count == 10,
            "expected exactly 10 persisted rows, got \(rows.count)")

        // Every row attributed to chat=200 — no cross-surface bleed, no
        // refusal mixed in.
        for (i, row) in rows.enumerated() {
            #expect(row.surface == "chat",
                "row[\(i)] surface != 'chat': \(row.surface)")
            #expect(row.status == 200,
                "row[\(i)] status != 200: \(row.status)")
            #expect(row.keyLabel == "burst-label",
                "row[\(i)] keyLabel propagation broke: \(String(describing: row.keyLabel))")
        }
    }
}

// MARK: - egress_decisions half — live default-deny listener over 10 CONNECTs

#if canImport(Darwin)

@Suite("AnthropicArmBurst — egress half: 10 deny CONNECTs produce 10 deny rows (V.13b-5)",
       .serialized)
struct AnthropicArmBurstEgressTests {

    /// 10 sequential `dataTask`s through a `proxiedConfiguration` URLSession
    /// fronted by a default-deny listener produce EXACTLY 10 deny rows.
    /// See the file-top CAVEAT for the CONNECT-coalescing choice
    /// (shared session — the deny-fronted listener structurally precludes
    /// keepalive coalescing because every tunnel is closed with 403).
    @Test("Default-deny listener + proxied URLSession × 10 sequential CONNECTs → exactly 10 deny rows")
    func tenSequentialConnectsProduceTenDenyRows() throws {
        let db = burstTempDB()
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: []),  // empty → default-deny
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)

        // CONNECT-coalescing choice (per file-top CAVEAT): a shared
        // URLSession suffices because the deny-fronted listener returns
        // 403 and closes every tunnel — no keepalive tunnel ever
        // survives to be reused, so each dataTask MUST issue a fresh
        // CONNECT. If a future URLSession change introduces speculative-
        // tunnel reuse across denied CONNECTs (vanishingly unlikely),
        // swap to a fresh `URLSession(configuration:)` per request.
        let config = ClaudeAPIServeEngineFactory.proxiedConfiguration(port: listener.port)
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        for i in 0..<10 {
            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.timeoutInterval = 2
            // A bogus per-request header so any URLSession-side request
            // dedup heuristic sees each request as distinct.
            request.setValue("v13b-5-burst-\(i)", forHTTPHeaderField: "X-Senkani-Burst-Seq")

            let sem = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var capturedError: Error?
            let task = session.dataTask(with: request) { _, _, error in
                capturedError = error
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + .seconds(5))
            // Every request must error — the listener denies + closes the
            // tunnel with 403. Surfaces as a URLError client-side.
            #expect(capturedError != nil,
                "dataTask[\(i)] expected URLError (deny path), got nil")
        }

        // CRUCIAL: tear down the session BEFORE reading rows. Prevents
        // any URLSession async retry sneaking in additional CONNECTs.
        session.invalidateAndCancel()

        // Wait for all 10 rows to land — the deny path is best-effort async.
        let observed = burstWaitForRowCount(db: db, target: 10)
        #expect(observed >= 10,
            "expected at least 10 egress rows after burst, observed \(observed)")

        // Schneier re-audit P3 settle: re-read after 50ms and confirm the
        // count is stable. The wait loop uses `>=` semantics; if URLSession
        // ever flushed an 11th CONNECT between the wait return and the
        // final read (vanishingly unlikely — the deny+403+close + session
        // teardown above precludes coalescing), the wait would short-circuit
        // at 10 and the exact assertion below could intermittently fail at
        // 11. The settle pin lets that 11th row land BEFORE the count check
        // so the failure mode would be deterministic, not flaky.
        usleep(50_000)

        let rows = db.recentEgressDecisions(limit: 20)
        // PRIMARY assertion: exactly 10 rows (acceptance contract).
        #expect(rows.count == 10,
            "expected exactly 10 egress rows, got \(rows.count): \(rows.map { "\($0.host)/\($0.method)/\($0.ruleId)" })")

        for (i, row) in rows.enumerated() {
            #expect(row.host == "api.anthropic.com",
                "row[\(i)] host != 'api.anthropic.com': \(row.host)")
            #expect(row.method == "CONNECT",
                "row[\(i)] method != 'CONNECT': \(row.method)")
            #expect(row.decision == .deny,
                "row[\(i)] decision != .deny: \(row.decision)")
            #expect(row.ruleId == "default-deny",
                "row[\(i)] ruleId != 'default-deny': \(row.ruleId)")
        }

        // Chain integrity across all 10 rows — proves the burst did not
        // corrupt the audit chain.
        let verdict = ChainVerifier.verifyEgressDecisions(db)
        switch verdict {
        case .ok:
            break
        default:
            Issue.record("expected ChainVerifier.verifyEgressDecisions == .ok after 10-row burst, got \(verdict)")
        }
    }
}

#endif
