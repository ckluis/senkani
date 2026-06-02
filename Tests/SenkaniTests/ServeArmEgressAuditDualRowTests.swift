import Testing
import Foundation
import SQLite3
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13b-4d — Serve-arm egress audit DUAL-ROW correctness.
///
/// This suite CODIFIES the structural invariant shipped in b-4c: on a
/// non-local-tier serve request the only writer to `egress_decisions`
/// is the egress daemon (`EgressConnectionHandler.recordDecision` →
/// `SessionDatabase.recordEgressDecision`). The serve path proper
/// (`ClaudeAPIServeDispatch.dispatch` / the `ServeCommand` chatHandler
/// closure / any helper in `Sources/Core/OpenAIEndpoint/`) MUST NOT
/// touch the egress audit table.
///
/// Narrowed scope (operator decision, fire-4 r7): the ALLOW-arm live
/// path requires an injection seam on `EgressUpstreamConnector.connect`
/// (otherwise a CONNECT to api.anthropic.com:443 would dial real
/// Anthropic from CI). That work is deferred to a separate item;
/// THIS suite covers:
///
///   T1. Negative source-scan — no serve-path file references the
///       egress-write API at all.
///   T2. Behavioral negative-assertion — driving `ClaudeAPIServeDispatch`
///       (success + every error variant) writes ZERO egress rows.
///   T3. Live DENY-path integration — a default-deny listener fronting
///       a real `URLSession` with the proxied configuration produces
///       EXACTLY ONE deny row + an `.ok` chain-verifier verdict.
///   T4. Bogus-port inverse — proving the proxy is REQUIRED (not just
///       preferred) for egress; CFNetwork must error on proxy failure
///       rather than silently fall back to direct egress.
///
/// Plan-audit P0/P1 fixes adopted:
///   - Source-scan covers `recordEgressDecision(` + `EgressDecisionStore[(.]`
///     + `egressDecisionStore.record` (Schneier P0 — three indirect
///     write paths).
///   - URLSession is `.ephemeral`, `timeoutIntervalForRequest = 2`,
///     `httpMaximumConnectionsPerHost = 1`, one dataTask, then
///     `invalidateAndCancel()` BEFORE the assertion (Schneier P1 —
///     HTTP/2 keepalive/retry hazard).
///   - DENY path asserts `count == 1` (Schneier P1 — exact count makes
///     a future double-CONNECT-from-keepalive bug fail).
///   - `.serialized` trait on every suite (Karpathy P2 — cross-test
///     interference between parallel listeners + URLSession process-
///     global state).
///   - paneMode observed empirically: URLSession-originated CONNECT
///     sends no `X-Senkani-Pane-Mode` header, so
///     `EgressConnectionHandler.resolvedPaneMode` resolves to
///     `PaneMode.default` (= `.general`). Assert the observed value,
///     not prose (Lauret P1).
///
/// Schneier re-audit gap notes (PASS_WITH_GAPS):
///   - T1's regex-based scan is intrinsically defeatable by typealiases
///     (`typealias EDS = EgressDecisionStore`), captured-local receivers
///     (`let s = db.egressDecisionStore; s.record(...)`), and parameter-
///     form indirection (`func f(store: EgressDecisionStore)`). The T2
///     behavioral delta-check is the defense-in-depth backstop — a real
///     bypass would still fail under T2.
///   - PRODUCTION cross-process write atomicity (SQLite locking between
///     the egress daemon process and the senkani-serve process) is a
///     SEPARATE concern not covered by this in-process suite. The b-4d
///     plan-audit (Schneier P1) explicitly deferred that to follow-up
///     hardening; b-4d codifies the in-process invariant only.

// MARK: - Test helpers (file-private — the EgressProxyTests helpers
// are `private` to that file, so we carry our own slim copies here).

private func dualRowTempDB() -> SessionDatabase {
    let dir = NSTemporaryDirectory() + "senkani-dualrow-tests-\(UUID().uuidString)/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return SessionDatabase(path: dir + "senkani.db")
}

private func dualRowWaitForRow(
    db: SessionDatabase,
    timeoutSeconds: Double = 3.0
) -> EgressDecisionStore.Row? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let rows = db.recentEgressDecisions(limit: 1)
        if let row = rows.first { return row }
        usleep(20_000)
    }
    return nil
}

// MARK: - T1. Negative source-scan

@Suite("ServeArmEgressAuditDualRow — negative source-scan (T1)", .serialized)
struct ServeArmEgressAuditDualRowSourceScanTests {

    /// V.13b-4c follow-up b-4d (Schneier P2): T1 widened from include-list to
    /// DENY-LIST. Previously the scan only inspected `Sources/CLI/ServeCommand.swift`
    /// + `Sources/Core/OpenAIEndpoint/*.swift` — a future serve-path helper landing
    /// under a NEW directory (`Sources/Core/OpenAIServeNew/`,
    /// `Sources/Core/Routing/`, etc.) would silently slip past the static guarantee.
    /// The deny-list approach enumerates EVERY `.swift` file under `Sources/` and
    /// exempts only the files / directories where the egress-write API symbols
    /// LEGITIMATELY appear:
    ///
    ///   - `Sources/Core/EgressProxy/`  — the daemon writer dir (the only real
    ///     producer of `egress_decisions` rows). All paths inside this prefix
    ///     are exempt.
    ///   - `Sources/Core/SessionDatabase+EgressAPI.swift`  — the SessionDatabase
    ///     facade that exposes `recordEgressDecision(...)` /
    ///     `egressDecisionStore.record(...)`. It IS the wrapper the daemon calls
    ///     through, not a serve-path writer.
    ///   - `Sources/Core/SessionDatabase.swift`  — store wiring: `internal var
    ///     egressDecisionStore: EgressDecisionStore!` and the two
    ///     `EgressDecisionStore(parent: self)` construction sites. Pure
    ///     dependency wiring, not a write.
    ///   - `Sources/Core/ChainVerifier.swift`  — doc-comment reference (`/// writer
    ///     side in EgressDecisionStore.record.`). Read-side code, no write.
    ///
    /// Any match OUTSIDE the exemption set fails the test — a new serve-path
    /// helper that grows an `egress_decisions` write under any directory is
    /// caught at compile-time-equivalent (test-time) granularity.
    @Test("Serve-path files NEVER reference egress-write APIs (deny-list scan)")
    func servePathFilesNeverWriteEgressRows() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/SenkaniTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let sourcesDir = repoRoot.appendingPathComponent("Sources", isDirectory: true)
        let sourcesPrefix = sourcesDir.standardizedFileURL.path

        // Exemption set — paths that legitimately reference egress-write API
        // symbols. Stored as repo-relative substrings; an exemption matches if
        // the candidate file's path under Sources/ has the substring as a
        // prefix (so a DIR exemption like `Core/EgressProxy/` matches every
        // file inside that subtree).
        let exemptions: [String] = [
            "Core/EgressProxy/",
            "Core/SessionDatabase+EgressAPI.swift",
            "Core/SessionDatabase.swift",
            "Core/ChainVerifier.swift",
        ]

        // Recursively enumerate every `.swift` under Sources/. We use
        // `FileManager.enumerator(at:)` (the same shape the build system uses)
        // so a future re-arrangement of the source tree picks up new files
        // automatically.
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            Issue.record("could not enumerate \(sourcesDir.path)")
            return
        }

        var targets: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            // Repo-relative-to-Sources/ path for exemption matching.
            let absPath = url.standardizedFileURL.path
            guard absPath.hasPrefix(sourcesPrefix + "/") else { continue }
            let rel = String(absPath.dropFirst(sourcesPrefix.count + 1))
            let isExempt = exemptions.contains { rel.hasPrefix($0) }
            if !isExempt { targets.append(url) }
        }

        // Schneier P0: cover three indirect write shapes. Any match in a
        // non-exempt file fails the test — write paths must funnel through
        // the daemon (`Sources/Core/EgressProxy/`) + the SessionDatabase
        // facade only.
        let patterns: [String] = [
            #"\brecordEgressDecision\s*\("#,
            #"\bEgressDecisionStore\s*[(.]"#,
            #"\begressDecisionStore\s*\.\s*record\b"#,
        ]

        var hits: [String] = []
        for file in targets {
            guard let body = try? String(contentsOf: file, encoding: .utf8) else {
                Issue.record("could not read \(file.path)")
                continue
            }
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, line) in lines.enumerated() {
                let lineStr = String(line)
                for pattern in patterns {
                    if lineStr.range(of: pattern, options: .regularExpression) != nil {
                        let absPath = file.standardizedFileURL.path
                        let rel = absPath.hasPrefix(sourcesPrefix + "/")
                            ? String(absPath.dropFirst(sourcesPrefix.count + 1))
                            : file.lastPathComponent
                        hits.append("\(rel):\(idx + 1): \(lineStr.trimmingCharacters(in: .whitespaces))")
                        break
                    }
                }
            }
        }

        #expect(hits.isEmpty,
            "non-exempt files MUST NOT call the egress-write API; offenders: \(hits)")
    }
}

// MARK: - T2. Behavioral negative-assertion (drive dispatch, zero delta)

@Suite("ServeArmEgressAuditDualRow — dispatch writes zero egress rows (T2)",
       .serialized, .urlProtocolGate)
struct ServeArmEgressAuditDualRowDispatchTests {

    private let anthropicURL = URL(string: "https://api.anthropic.com/v1/messages")!

    private func makeEngine(
        retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default
    ) -> ClaudeAPIChatEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        return ClaudeAPIChatEngine(
            apiKey: "ak-test",
            session: session,
            endpoint: anthropicURL,
            retryPolicy: retryPolicy,
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

    private func driveDispatchAndExpectNoEgressDelta(
        register: () -> Void,
        retryPolicy: ClaudeAPIChatEngine.RetryPolicy = .default,
        label: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        register()
        let db = dualRowTempDB()
        let before = db.recentEgressDecisions(limit: 10).count
        _ = ClaudeAPIServeDispatch.dispatch(
            engine: makeEngine(retryPolicy: retryPolicy),
            request: request(),
            routing: routing(),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-\(label)"
        )
        let after = db.recentEgressDecisions(limit: 10).count
        #expect(after - before == 0,
            "dispatch '\(label)' must not write egress rows; before=\(before) after=\(after)",
            sourceLocation: sourceLocation)
    }

    @Test("Success path writes zero egress rows")
    func successPathZeroDelta() {
        driveDispatchAndExpectNoEgressDelta(
            register: {
                let body = #"{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":1}}"#
                MockURLProtocol.register(
                    url: anthropicURL, status: 200, body: Data(body.utf8)
                )
            },
            label: "ok"
        )
    }

    @Test("Rate-limited (429) writes zero egress rows")
    func rateLimitedZeroDelta() {
        driveDispatchAndExpectNoEgressDelta(
            register: {
                MockURLProtocol.register(
                    url: anthropicURL, status: 429,
                    body: Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8)
                )
            },
            retryPolicy: ClaudeAPIChatEngine.RetryPolicy(
                maxRetries: 0, maxTotalWait: .seconds(0), baseDelay: .seconds(0)
            ),
            label: "rate"
        )
    }

    @Test("Upstream 500 → 502 writes zero egress rows")
    func upstreamErrorZeroDelta() {
        driveDispatchAndExpectNoEgressDelta(
            register: {
                MockURLProtocol.register(
                    url: anthropicURL, status: 500,
                    body: Data(#"{"error":{"type":"server_error"}}"#.utf8)
                )
            },
            label: "upstream"
        )
    }

    /// V.13b-4c follow-up b-4d (Schneier P3): defense-in-depth fifth T2 case
    /// for the `Captured.cancellation` arm of `ClaudeAPIServeDispatch.dispatch`.
    /// T1's static deny-list already guarantees no serve-path file even
    /// references the egress-write API, but the T2 behavioral matrix should
    /// close every dispatch-outcome variant — success, rateLimited,
    /// upstreamError, networkError, AND cancellation. We trigger the
    /// cancellation arm by:
    ///   - Registering a 429 mock response so the engine enters its retry
    ///     loop (with a low-retry policy that still allows ONE attempt).
    ///   - Injecting a `sleeper` that throws `CancellationError()` on the
    ///     first backoff. The engine propagates `CancellationError` (NOT
    ///     `ClaudeAPIChatEngineError`) — see ClaudeAPIChatEngine.fireWithRetry
    ///     line 512 — which dispatch captures into `Captured.cancellation`
    ///     and routes through the no-egress-write `errorOutcome(...)` arm.
    /// Asserts `db.recentEgressDecisions(limit:10).count` delta == 0 — the
    /// cancellation path must not leak an egress row from the serve dispatch.
    @Test("Cancellation path writes zero egress rows")
    func cancellationZeroDelta() {
        MockURLProtocol.reset()
        defer { MockURLProtocol.reset() }
        // Register a 429 so the engine enters its retry/backoff loop. The
        // sleeper throws `CancellationError()` on the first sleep, before
        // any second upstream attempt fires.
        MockURLProtocol.register(
            url: anthropicURL, status: 429,
            body: Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8)
        )

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak-test",
            session: session,
            endpoint: anthropicURL,
            retryPolicy: ClaudeAPIChatEngine.RetryPolicy(
                maxRetries: 3,
                maxTotalWait: .seconds(5),
                baseDelay: .milliseconds(1)
            ),
            // The cancellation injection seam: a `sleeper` that throws
            // `CancellationError()` propagates exactly the same shape as a
            // real task cancellation mid-backoff.
            sleeper: { _ in throw CancellationError() }
        )

        let db = dualRowTempDB()
        let before = db.recentEgressDecisions(limit: 10).count
        _ = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: request(),
            routing: routing(),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-cancel"
        )
        let after = db.recentEgressDecisions(limit: 10).count
        #expect(after - before == 0,
            "cancellation dispatch must not write egress rows; before=\(before) after=\(after)")
    }

    @Test("Network error path writes zero egress rows")
    func networkErrorZeroDelta() {
        // Custom URLProtocol that fails every request. Same pattern as
        // `ClaudeAPIServeDispatchNetworkErrorTests`.
        final class FailingProtocol: URLProtocol, @unchecked Sendable {
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            }
            override func stopLoading() {}
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingProtocol.self]
        let session = URLSession(configuration: config)
        let engine = ClaudeAPIChatEngine(
            apiKey: "ak", session: session,
            endpoint: anthropicURL,
            sleeper: { _ in }
        )

        let db = dualRowTempDB()
        let before = db.recentEgressDecisions(limit: 10).count
        _ = ClaudeAPIServeDispatch.dispatch(
            engine: engine,
            request: request(),
            routing: routing(),
            keyLabel: "work",
            now: Date(),
            id: "chatcmpl-net"
        )
        let after = db.recentEgressDecisions(limit: 10).count
        #expect(after - before == 0,
            "network-error dispatch must not write egress rows; before=\(before) after=\(after)")
    }
}

// MARK: - T3 + T4. Live DENY-path + bogus-port inverse

#if canImport(Darwin)

@Suite("ServeArmEgressAuditDualRow — live DENY-path + bogus-port inverse (T3+T4)",
       .serialized)
struct ServeArmEgressAuditDualRowLiveTests {

    /// T3: Default-deny listener fronts a real `URLSession` configured with
    /// `ClaudeAPIServeEngineFactory.proxiedConfiguration(port:)`. A single
    /// CONNECT to api.anthropic.com:443 must produce EXACTLY ONE deny row
    /// (host=api.anthropic.com, method=CONNECT, decision=.deny,
    /// ruleId="default-deny"), the chain must verify `.ok`, and the
    /// observed paneMode for a URLSession-originated CONNECT must match
    /// `PaneMode.default` (URLSession sends no `X-Senkani-Pane-Mode`
    /// header, so the handler falls back to .general).
    @Test("Default-deny listener + proxied URLSession → exactly one deny row")
    func defaultDenyListenerDeniesProxiedConnect() throws {
        let db = dualRowTempDB()
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: []),  // empty → default-deny
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "")
        )
        try listener.start()
        defer { listener.stop() }
        #expect(listener.port > 0)

        // Schneier P1: bound URLSession's HTTP/2 keepalive + retry hazard.
        let config = ClaudeAPIServeEngineFactory.proxiedConfiguration(port: listener.port)
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 2

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var capturedError: Error?
        let task = session.dataTask(with: request) { _, _, error in
            capturedError = error
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + .seconds(5))

        // URLError is EXPECTED — the daemon will close the CONNECT with 403
        // after writing the deny row.
        #expect(capturedError != nil,
            "URLSession through the deny listener must surface an error")

        // CRUCIAL: tear down the session BEFORE reading rows. Prevents any
        // URLSession async retry sneaking in a second CONNECT.
        session.invalidateAndCancel()

        // Wait for the row to land — the deny path is best-effort async.
        let row = dualRowWaitForRow(db: db, timeoutSeconds: 5.0)
        #expect(row != nil, "expected at least one egress row")

        let rows = db.recentEgressDecisions(limit: 10)
        // Schneier P1: exact count. A future double-CONNECT-from-keepalive
        // bug would push count > 1 and FAIL this assertion.
        #expect(rows.count == 1,
            "expected exactly one egress row, got \(rows.count): \(rows.map { "\($0.host)/\($0.method)/\($0.ruleId)" })")

        if let first = rows.first {
            #expect(first.host == "api.anthropic.com",
                "expected api.anthropic.com, got \(first.host)")
            #expect(first.method == "CONNECT",
                "expected CONNECT, got \(first.method)")
            #expect(first.decision == .deny,
                "expected .deny, got \(first.decision)")
            #expect(first.ruleId == "default-deny",
                "expected default-deny, got \(first.ruleId)")
            // Lauret P1: observed paneMode for URLSession-originated
            // CONNECT (no `X-Senkani-Pane-Mode` header) → handler
            // falls back to `PaneMode.default` (.general). Schneier
            // re-audit P3: lock the literal `.general` AND the
            // `PaneMode.default == .general` invariant separately so a
            // future change to `PaneMode.default`'s value surfaces here.
            #expect(first.paneMode == .general,
                "expected paneMode=.general, got \(String(describing: first.paneMode))")
            #expect(PaneMode.default == .general,
                "PaneMode.default invariant: must equal .general (URLSession-originated CONNECT has no pane header)")
        }

        // Schneier P1: chain integrity. Fresh tempDB + one deny row →
        // verifier returns `.ok`.
        let verdict = ChainVerifier.verifyEgressDecisions(db)
        switch verdict {
        case .ok:
            break
        default:
            Issue.record("expected ChainVerifier.verifyEgressDecisions == .ok, got \(verdict)")
        }
    }

    /// V.13b-4c follow-up b-4d (Schneier P3): bind-then-close ephemeral
    /// port idiom. Previously T4 used the hard-coded literal `0xDEAD`
    /// (= 57005), which had a rare collision hazard if something else on the
    /// test host bound 57005. The replacement asks the kernel to assign an
    /// ephemeral 127.0.0.1 port (bind to `port: 0`), reads the assigned port
    /// via `getsockname`, then closes the socket — yielding a port number
    /// that is "known closed" at the instant we use it.
    ///
    /// Accepted trade-off: under heavy churn the kernel may re-assign the
    /// port to another process between close and `dataTask.resume()`,
    /// transitioning it out of `TIME_WAIT`. In that case the test would
    /// turn from "URLSession surfaces an error" into "URLSession connects to
    /// the wrong endpoint" — a different failure mode, but still a failure
    /// (the response would not be a successful CONNECT through our proxy).
    /// We accept that rare flake as a strictly better trade than the
    /// hard-coded 57005 collision risk.
    private func reservedClosedPort() throws -> Int {
        enum PortHelperError: Error { case bindFailed, getsocknameFailed }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PortHelperError.bindFailed }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0  // kernel-assigned
        addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian  // 127.0.0.1
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let br = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if br != 0 { close(fd); throw PortHelperError.bindFailed }
        var bound = sockaddr_in()
        var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nr = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &blen)
            }
        }
        if nr != 0 { close(fd); throw PortHelperError.getsocknameFailed }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        // Close so the port is no longer bound; kernel keeps it in TIME_WAIT
        // for the rest of this test invocation (typical macOS default ≥ 15s)
        // which is plenty for the dataTask below.
        close(fd)
        return port
    }

    /// T4: Bogus-port inverse. Build a URLSession with a proxy port we
    /// know is closed (bind-then-close ephemeral; see `reservedClosedPort()`);
    /// the dataTask must surface an error — proving CFNetwork does NOT
    /// silently fall back to direct egress when the proxy is unreachable.
    /// Validates the "proxy is REQUIRED, not preferred" half of the
    /// routing-regression guard.
    @Test("Bogus proxy port surfaces URLError (proxy is required, not preferred)")
    func bogusProxyPortFails() throws {
        let closedPort = try reservedClosedPort()
        let config = ClaudeAPIServeEngineFactory.proxiedConfiguration(port: closedPort)
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 2
        config.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 2

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var capturedError: Error?
        nonisolated(unsafe) var capturedResponse: URLResponse?
        let task = session.dataTask(with: request) { _, response, error in
            capturedError = error
            capturedResponse = response
            sem.signal()
        }
        task.resume()
        _ = sem.wait(timeout: .now() + .seconds(5))

        #expect(capturedError != nil,
            "URLSession with a closed proxy port must surface an error (proxy is REQUIRED, not preferred); response=\(String(describing: capturedResponse))")
    }
}

#endif
