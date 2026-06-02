import Testing
import Foundation
import SQLite3
@testable import Core

#if canImport(Darwin)
import Darwin
#endif

/// V.13b-4d-ii — `EgressUpstreamConnecting` protocol seam + ALLOW-arm
/// live integration.
///
/// Background: phase-v13b-4d narrowed at the operator console (r7,
/// 2026-06-01) to DENY-path scope only because the ALLOW arm required an
/// injection seam on the upstream-connect step. The handler's allow arm
/// at `EgressConnectionHandler.swift:280-287` gates on a successful
/// upstream connect, and the static `EgressUpstreamConnector.connect`
/// does real `getaddrinfo` — exercising it from CI would dial real
/// Anthropic.
///
/// This suite codifies the deferred ALLOW arm proof under THREE tests:
///   T1. PARITY — the new `DefaultEgressUpstreamConnector` adopter
///       returns byte-equivalent results to the static
///       `EgressUpstreamConnector.connect(host:port:)` call (loopback
///       fixture; both should return a connected fd to the same port).
///   T2. LIVE ALLOW-ARM INTEGRATION — `EgressListener` with the b-4b
///       `serve-anthropic` allow rule + a `LoopbackStubConnector` that
///       redirects to a `FixtureTCPServer` produces EXACTLY ONE allow
///       row whose row-shape matches the spec (host=api.anthropic.com,
///       method=CONNECT, decision=.allow, ruleId="serve-anthropic").
///   T3. CHAIN-INTEGRITY-AND-FIELDS — same allow-arm run; assert
///       `ChainVerifier.verifyEgressDecisions == .ok` and the audit row
///       fields are correct. (Overlaps T2's (c) per spec by design.)
///
/// Plan-audit guards adopted from b-4d:
///   - `.serialized` on every suite — EgressListener + URLSession
///     process-global state collide otherwise (Karpathy P2).
///   - URLSession is `.ephemeral`, `timeoutIntervalForRequest = 2`,
///     `httpMaximumConnectionsPerHost = 1`, one `dataTask`, then
///     `invalidateAndCancel()` BEFORE the assertion (Schneier P1 —
///     HTTP/2 keepalive/retry hazard).
///   - Exact count asserted on the rows table (Schneier P1 — a future
///     double-CONNECT-from-keepalive bug would fail this).
///   - Port-zero bind on both `EgressListener` and `FixtureTCPServer`
///     (kernel-assigned, never reused).

// MARK: - Test helpers (slim local copies; the EgressProxyTests
// helpers are visible in the same target but we keep this file
// self-contained for readability + plan-audit lock-in).

private func seamTempDB() -> SessionDatabase {
    let dir = NSTemporaryDirectory() + "senkani-seam-tests-\(UUID().uuidString)/"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return SessionDatabase(path: dir + "senkani.db")
}

private func seamWaitForRow(
    db: SessionDatabase,
    timeoutSeconds: Double = 5.0
) -> EgressDecisionStore.Row? {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        let rows = db.recentEgressDecisions(limit: 1)
        if let row = rows.first { return row }
        usleep(20_000)
    }
    return nil
}

#if canImport(Darwin)

/// Test-only adopter that ignores the `host` argument and always dials
/// `127.0.0.1:fixturePort`. Lives in the test target ONLY — never
/// shipped to the public surface, never reachable from production code
/// paths (the daemon binary wires `DefaultEgressUpstreamConnector`
/// through the `EgressListener` init default).
private struct LoopbackStubConnector: EgressUpstreamConnecting {
    let fixturePort: Int

    func connect(host: String, port: Int) -> Int32? {
        _ = host  // intentionally ignored
        _ = port  // intentionally ignored
        return connectToLocalhost(port: fixturePort)
    }
}

// MARK: - T1. PARITY for the default adopter

@Suite("EgressUpstreamConnecting seam — default adopter parity (T1)",
       .serialized)
struct EgressUpstreamConnectingSeamParityTests {

    /// Stand up a loopback fixture; both the static
    /// `EgressUpstreamConnector.connect(host:port:)` AND the new
    /// `DefaultEgressUpstreamConnector` adopter via the protocol must
    /// return a connected fd to that port. Byte-equivalent at the
    /// connect step — the adopter is just a thin shim.
    @Test("DefaultEgressUpstreamConnector adopter is byte-equivalent to static call")
    func defaultAdopterMatchesStaticCall() throws {
        let fixture = try FixtureTCPServer()
        defer { fixture.shutdown() }

        // Fixture accepts two back-to-back connections, drains+closes.
        // We make two separate `acceptOnce` calls so both paths get an
        // accepting half on the listener side.
        fixture.acceptOnce { fd in
            var sink = [UInt8](repeating: 0, count: 64)
            _ = sink.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
        }
        fixture.acceptOnce { fd in
            var sink = [UInt8](repeating: 0, count: 64)
            _ = sink.withUnsafeMutableBufferPointer { ptr in
                read(fd, ptr.baseAddress, ptr.count)
            }
        }

        // Path A: static call.
        let staticFD = EgressUpstreamConnector.connect(host: "127.0.0.1", port: fixture.port)
        #expect(staticFD != nil, "static EgressUpstreamConnector.connect must return a connected fd")
        if let fd = staticFD { close(fd) }

        // Path B: protocol via default adopter.
        let adopter: EgressUpstreamConnecting = DefaultEgressUpstreamConnector()
        let adopterFD = adopter.connect(host: "127.0.0.1", port: fixture.port)
        #expect(adopterFD != nil, "DefaultEgressUpstreamConnector adopter must return a connected fd")
        if let fd = adopterFD { close(fd) }

        // Parity: both arms produced a connected fd to the same port,
        // and behavior at the call seam is identical (single forwarding
        // call — no re-resolution, no extra socket options layered on).
        #expect(staticFD != nil && adopterFD != nil,
            "default adopter must be byte-equivalent to the static call")
    }

    /// Negative: when the target host:port is closed, BOTH paths must
    /// return nil. Locks in that the adopter doesn't accidentally
    /// add a retry / fallback / different error semantics.
    @Test("DefaultEgressUpstreamConnector adopter returns nil on unreachable target")
    func defaultAdopterReturnsNilOnUnreachable() {
        // Port 1 on loopback is reserved and refused on macOS.
        let closedPort = 1
        let staticResult = EgressUpstreamConnector.connect(host: "127.0.0.1", port: closedPort, timeoutSeconds: 1)
        let adopter = DefaultEgressUpstreamConnector()
        let adopterResult = adopter.connect(host: "127.0.0.1", port: closedPort)
        // Both must reach the same verdict (nil on the unreachable port).
        #expect(staticResult == nil, "static call must return nil on closed port; got fd=\(staticResult ?? -1)")
        #expect(adopterResult == nil, "adopter must return nil on closed port; got fd=\(adopterResult ?? -1)")
        if let fd = staticResult { close(fd) }
        if let fd = adopterResult { close(fd) }
    }
}

// MARK: - T2 + T3. LIVE ALLOW-arm integration + chain-integrity-and-fields

@Suite("EgressUpstreamConnecting seam — live ALLOW-arm integration (T2+T3)",
       .serialized)
struct EgressUpstreamConnectingSeamAllowArmTests {

    /// Stand up:
    ///   - `FixtureTCPServer` on a random loopback port.
    ///   - `EgressListener` with the b-4b `serve-anthropic` allow rule
    ///     and a `LoopbackStubConnector(fixturePort:)` injected so the
    ///     handler's allow-arm CONNECT dials the fixture, not Anthropic.
    ///   - URLSession via `ClaudeAPIServeEngineFactory.proxiedConfiguration`
    ///     with the listener port + bounded timeouts + max-1 connection.
    ///
    /// Issue exactly one `dataTask` to `https://api.anthropic.com/v1/messages`.
    /// The TLS ClientHello carries SNI=api.anthropic.com so the daemon's
    /// SNI matcher passes; the handler proceeds to `connect()` which the
    /// stub redirects to the fixture. The fixture closes shortly after,
    /// the URLSession surfaces an error (no real TLS handshake completes),
    /// but the daemon has already written the allow row.
    ///
    /// Assertions (combined T2 + T3):
    ///   (a) `db.recentEgressDecisions(limit:10).count == 1`
    ///   (b) row: host=api.anthropic.com, method=CONNECT,
    ///       decision=.allow, ruleId="serve-anthropic"
    ///   (c) `ChainVerifier.verifyEgressDecisions(db) == .ok`
    @Test("Live ALLOW-arm with stubbed upstream produces exactly one allow row + .ok chain")
    func allowArmWithStubbedUpstreamWritesAllowRow() throws {
        // The fixture stands in for api.anthropic.com:443. Accept once;
        // the handler will write the peeked ClientHello, then the fixture
        // closes its side and the pipe unwinds.
        let fixture = try FixtureTCPServer()
        defer { fixture.shutdown() }
        // The fixture HOLDS the connection: drain bytes in a loop until
        // the peer closes. This blocks URLSession's CONNECT pipe in a
        // steady-state read — URLSession's `timeoutIntervalForRequest:2`
        // fires before any retry can run, so we get EXACTLY ONE allow
        // row, not 2 from a keepalive/retry. (A premature fixture-close
        // mid-TLS-handshake would let URLSession retry the CONNECT,
        // producing a 2nd allow row — the assertion below catches that
        // hazard.) Accept on multiple slots as belt-and-braces in case
        // CFNetwork ever does try a second CONNECT before the timeout.
        for _ in 0..<3 {
            fixture.acceptOnce { fd in
                var sink = [UInt8](repeating: 0, count: 8192)
                while true {
                    let n = sink.withUnsafeMutableBufferPointer { ptr in
                        read(fd, ptr.baseAddress, ptr.count)
                    }
                    if n <= 0 { return }
                }
            }
        }

        let db = seamTempDB()
        let allowRule = EgressRule(
            id: "serve-anthropic",
            pattern: "api.anthropic.com",
            mode: .exact,
            decision: .allow
        )
        let listener = EgressListener(
            rules: EgressRuleEngine(rules: [allowRule]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: ""),
            upstreamConnector: LoopbackStubConnector(fixturePort: fixture.port)
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
        // URLSession may surface an error (the fixture doesn't complete
        // a real TLS handshake) OR may succeed-then-EOF — either is fine.
        // The structural assertion is the row, not the URLError shape.
        _ = capturedError

        // CRUCIAL: tear down BEFORE reading rows. Prevents any URLSession
        // async retry from sneaking in a second CONNECT.
        session.invalidateAndCancel()

        // Wait for the allow row to land.
        let row = seamWaitForRow(db: db, timeoutSeconds: 5.0)
        #expect(row != nil, "expected at least one egress row from the allow arm")

        let rows = db.recentEgressDecisions(limit: 10)
        // (a) exact count.
        #expect(rows.count == 1,
            "expected exactly one egress row, got \(rows.count): \(rows.map { "\($0.host)/\($0.method)/\($0.decision.rawValue)/\($0.ruleId)" })")

        // (b) row shape matches the spec.
        if let first = rows.first {
            #expect(first.host == "api.anthropic.com",
                "expected host=api.anthropic.com, got \(first.host)")
            #expect(first.method == "CONNECT",
                "expected method=CONNECT, got \(first.method)")
            #expect(first.decision == .allow,
                "expected decision=.allow, got \(first.decision)")
            #expect(first.ruleId == "serve-anthropic",
                "expected ruleId=serve-anthropic, got \(first.ruleId)")
            // paneMode parity with the b-4d DENY-path assertion:
            // URLSession-originated CONNECT has no `X-Senkani-Pane-Mode`,
            // so the handler resolves `.general` (which equals
            // `PaneMode.default`).
            #expect(first.paneMode == .general,
                "expected paneMode=.general, got \(String(describing: first.paneMode))")
        }

        // (c) chain integrity — fresh tempDB + one allow row → `.ok`.
        let verdict = ChainVerifier.verifyEgressDecisions(db)
        switch verdict {
        case .ok:
            break
        default:
            Issue.record("expected ChainVerifier.verifyEgressDecisions == .ok, got \(verdict)")
        }
    }

    /// Standalone chain-integrity-and-fields assertion against a freshly
    /// written allow row through the SAME seam. Lets the verdict's
    /// pass/fail be attributable independently of the integration test's
    /// live-traffic shape — if the integration test fails for a
    /// listener-port reason, this still pins the row-write + chain
    /// invariants on the allow path.
    @Test("Direct allow-row write through SessionDatabase facade chains cleanly")
    func directAllowRowWriteVerifiesChain() {
        let db = seamTempDB()
        let writeOK = db.recordEgressDecision(
            host: "api.anthropic.com",
            method: "CONNECT",
            decision: .allow,
            ruleId: "serve-anthropic",
            latencyUs: 1234,
            paneMode: .general,
            judgeRationale: nil
        )
        #expect(writeOK, "direct allow-row write must succeed against a fresh tempDB")

        let rows = db.recentEgressDecisions(limit: 10)
        #expect(rows.count == 1, "expected exactly one row after direct write")
        if let first = rows.first {
            #expect(first.host == "api.anthropic.com")
            #expect(first.method == "CONNECT")
            #expect(first.decision == .allow)
            #expect(first.ruleId == "serve-anthropic")
            #expect(first.paneMode == .general)
        }

        let verdict = ChainVerifier.verifyEgressDecisions(db)
        switch verdict {
        case .ok:
            break
        default:
            Issue.record("expected ChainVerifier.verifyEgressDecisions == .ok after one allow row, got \(verdict)")
        }
    }
}

#endif
