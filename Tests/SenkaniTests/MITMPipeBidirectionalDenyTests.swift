import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// r94 t1d-5 r52 Carmack/Allspaw panel APPENDs — LIVE `pipeBidirectional`
/// integration coverage.
///
/// The r94 work (commit 7ef5428) added the `InnerBodyDenyEvaluating`
/// connector seam + `DefaultInnerBodyDenyEvaluator` adapter +
/// `parseInnerHTTPHead` helper and WIRED them into
/// `MITMUpstreamVerify.pipeBidirectional`'s `.allow` rebind arm. But the
/// r94 unit tests (`MITMInnerBodyDenyTests`) exercise the adapter + parser
/// shape DIRECTLY — they build the evaluator call the way pipeBidirectional
/// would, but never DRIVE `pipeBidirectional` itself. The actual call site
/// (MITMUpstreamVerify.swift ~line 586) was STRUCTURALLY UNCOVERED.
///
/// This suite closes that gap. It stands up TWO real TLS legs over
/// `socketpair(2)` and drives the LIVE `pipeBidirectional`:
///
///   - Client leg: the proxy-side end is a SERVER SSLContext presenting a
///     TEST-CA leaf — this is pipeBidirectional's `clientSSL` (the
///     terminated-client side). The TEST drives the other end as a CLIENT
///     SSLContext that anchors the TEST CA and writes the inner HTTP
///     request the rebind peek reads.
///   - Upstream leg: the proxy-side end is a CLIENT SSLContext anchoring
///     the TEST CA — this is pipeBidirectional's `upstreamSSL`. The TEST
///     drives the other end as a SERVER SSLContext (the fake upstream) that
///     reads the replayed head bytes pipeBidirectional writes.
///
/// The panel APPENDs covered:
///   - Carmack P2-A: `mitm_inner_head_parse_failed` fail-CLOSED end-to-end.
///   - Carmack P2-B: pipeBidirectional actually invokes the injected
///     evaluator (deny verdict → `.bodyDeny`).
///   - Carmack P2-C / Allspaw exactly-once: the `onInnerBodyExcerpt`
///     callback fires EXACTLY ONCE on the `.allow` arm.
///   - Allspaw deny coverage: stub deny → `.bodyDeny` + ZERO bytes upstream
///     + audit ruleId verbatim + callback once.
///   - Allspaw default-deny coverage: default-deny sentinel → head-replay
///     PROCEEDS (no `.bodyDeny`).
///   - Allspaw P3 ruleId verbatim: the LIVE `.bodyDeny` outcome carries the
///     operator's ruleId verbatim (round-trips outcome through the pipe).
///   - Carmack P3-A: the `default-deny` string-literal sentinel comparison
///     at the call site — a `.deny` verdict whose ruleId == "default-deny"
///     does NOT body-deny (distinct from a real operator deny rule).
///
/// NOTE on the macOS-14 floor: SecureTransport (`SSLContext`,
/// `SSLSetIOFuncs`, `SecTrustEvaluateWithError`) is available on every
/// supported macOS — no `@available(macOS 15.0,*)` symbols are referenced,
/// so the suite runs unguarded on the macOS-14 floor.
@Suite("r94 t1d-5 — LIVE pipeBidirectional integration (Carmack/Allspaw APPENDs)", .serialized)
struct MITMPipeBidirectionalDenyTests {

    // MARK: - Temp-CA helpers (mirror MITMUpstreamVerifySeamTests)

    private func tempPaths() -> (MITMCertificateAuthority.Paths, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-pipe-deny-\(UUID().uuidString)", isDirectory: true)
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: dir.appendingPathComponent("egress-ca.pem").path,
            privateKeyPEM: dir.appendingPathComponent("egress-ca.key").path
        )
        return (paths, dir.path)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    private static func makeSocketPair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        precondition(rc == 0, "socketpair failed: \(rc)")
        return (fds[0], fds[1])
    }

    // MARK: - @convention(c) IO bridge (blocking loop — same as the spike)

    private final class IOContext {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
    }

    private static let sslReadFunc: SSLReadFunc = { connection, data, dataLength in
        let ctx = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        var got = 0
        let base = data.assumingMemoryBound(to: UInt8.self)
        while got < want {
            let n = Darwin.read(ctx.fd, base + got, want - got)
            if n > 0 { got += n; continue }
            if n == 0 { dataLength.pointee = got; return errSSLClosedGraceful }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                dataLength.pointee = got
                return errSSLWouldBlock
            }
            dataLength.pointee = got
            return errSSLClosedAbort
        }
        dataLength.pointee = got
        return errSecSuccess
    }

    private static let sslWriteFunc: SSLWriteFunc = { connection, data, dataLength in
        let ctx = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        var sent = 0
        let base = data.assumingMemoryBound(to: UInt8.self)
        while sent < want {
            let n = Darwin.write(ctx.fd, base + sent, want - sent)
            if n > 0 { sent += n; continue }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    dataLength.pointee = sent
                    return errSSLWouldBlock
                }
            }
            dataLength.pointee = sent
            return errSSLClosedAbort
        }
        dataLength.pointee = sent
        return errSecSuccess
    }

    // MARK: - Recording evaluator (drives the LIVE deny call site)

    /// Records each call pipeBidirectional makes into the seam and returns
    /// a canned verdict. Thread-safe — pipeBidirectional runs on a
    /// background thread.
    private final class RecordingEvaluator: InnerBodyDenyEvaluating, @unchecked Sendable {
        struct Call: Sendable {
            let host: String
            let method: String?
            let path: String?
            let headerCount: Int
            let bodyExcerpt: String?
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private let verdict: EgressEvaluation
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        init(verdict: EgressEvaluation) { self.verdict = verdict }
        func evaluate(host: String, method: String?, path: String?,
                      headers: [(name: String, value: String)],
                      bodyExcerpt: String?) -> EgressEvaluation {
            lock.lock()
            _calls.append(Call(host: host, method: method, path: path,
                               headerCount: headers.count, bodyExcerpt: bodyExcerpt))
            lock.unlock()
            return verdict
        }
    }

    /// Thread-safe box capturing the `onInnerBodyExcerpt` callback fires.
    private final class CallbackRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _fires: [(Data?, EgressBodyCaptureState)] = []
        var fires: [(Data?, EgressBodyCaptureState)] {
            lock.lock(); defer { lock.unlock() }
            return _fires
        }
        func record(_ body: Data?, _ state: EgressBodyCaptureState) {
            lock.lock(); _fires.append((body, state)); lock.unlock()
        }
    }

    // MARK: - Harness result

    private struct PipeResult {
        let outcome: MITMTermination.UpstreamOutcome
        /// Bytes the FAKE UPSTREAM read off the wire (the replayed head +
        /// any piped client bytes). EMPTY on a body-deny (upstream gets
        /// ZERO bytes).
        let upstreamReceived: Data
        let pipeJoined: Bool
        let handshakesOK: Bool
    }

    /// Drive a single LIVE `pipeBidirectional` run with `validatedHost`
    /// set. `clientRequest` is the inner HTTP request the TEST (acting as
    /// the real client) writes over the client TLS leg — the rebind peek
    /// reads it. Returns the pipe outcome + the bytes the fake upstream
    /// observed.
    private static func runPipe(
        host: String,
        serverIdentity: SecIdentity,
        caCert: SecCertificate,
        clientRequest: Data,
        evaluator: InnerBodyDenyEvaluating?,
        callback: ((Data?, EgressBodyCaptureState) -> Void)?
    ) -> PipeResult {
        // --- Client leg: proxy-side SERVER ctx (clientSSL) <-> test CLIENT ctx.
        let (proxyClientFD, testClientFD) = makeSocketPair()
        // --- Upstream leg: proxy-side CLIENT ctx (upstreamSSL) <-> test SERVER ctx.
        let (proxyUpstreamFD, testUpstreamFD) = makeSocketPair()

        // Heap-boxed IO contexts — kept alive for the whole run.
        let proxyClientCtx = IOContext(proxyClientFD)
        let testClientCtx = IOContext(testClientFD)
        let proxyUpstreamCtx = IOContext(proxyUpstreamFD)
        let testUpstreamCtx = IOContext(testUpstreamFD)

        func makeCtx(_ side: SSLProtocolSide, _ ioCtx: IOContext) -> SSLContext? {
            guard let ssl = SSLCreateContext(nil, side, .streamType) else { return nil }
            _ = SSLSetIOFuncs(ssl, sslReadFunc, sslWriteFunc)
            _ = SSLSetConnection(ssl, Unmanaged.passUnretained(ioCtx).toOpaque())
            _ = SSLSetProtocolVersionMin(ssl, .tlsProtocol12)
            return ssl
        }

        guard
            let proxyClientSSL = makeCtx(.serverSide, proxyClientCtx),
            let testClientSSL = makeCtx(.clientSide, testClientCtx),
            let proxyUpstreamSSL = makeCtx(.clientSide, proxyUpstreamCtx),
            let testUpstreamSSL = makeCtx(.serverSide, testUpstreamCtx)
        else {
            [proxyClientFD, testClientFD, proxyUpstreamFD, testUpstreamFD].forEach { Darwin.close($0) }
            return PipeResult(outcome: .upstreamContextCreateFailed,
                              upstreamReceived: Data(), pipeJoined: false, handshakesOK: false)
        }

        // Both proxy-side SERVER ctx (clientSSL) AND the test-side SERVER
        // ctx (fake upstream) present the SAME TEST-CA leaf identity.
        _ = SSLSetCertificate(proxyClientSSL, [serverIdentity] as CFArray)
        _ = SSLSetClientSideAuthenticate(proxyClientSSL, .neverAuthenticate)
        _ = SSLSetCertificate(testUpstreamSSL, [serverIdentity] as CFArray)
        _ = SSLSetClientSideAuthenticate(testUpstreamSSL, .neverAuthenticate)

        // Both CLIENT ctx pin the expected hostname + break on server auth
        // so we evaluate trust against the TEST CA (never System anchors).
        for clientSSL in [testClientSSL, proxyUpstreamSSL] {
            _ = SSLSetPeerDomainName(clientSSL, host, host.utf8.count)
            _ = SSLSetSessionOption(clientSSL, .breakOnServerAuth, true)
        }

        // Test-only TEST-CA trust evaluator for the two client legs.
        func evalTrust(_ ssl: SSLContext) {
            var peerTrust: SecTrust?
            if SSLCopyPeerTrust(ssl, &peerTrust) == errSecSuccess, let trust = peerTrust {
                _ = SecTrustSetAnchorCertificates(trust, [caCert] as CFArray)
                _ = SecTrustSetAnchorCertificatesOnly(trust, true)
                var err: CFError?
                _ = SecTrustEvaluateWithError(trust, &err)
            }
        }

        let handshakeGroup = DispatchGroup()
        let okBox = NSLock()
        var handshakesOK = true
        func markFail() { okBox.lock(); handshakesOK = false; okBox.unlock() }

        // CONCURRENCY NOTE: the four TLS handshakes + the pipe + the
        // upstream reader each run a BLOCKING busy-spin. We deliberately use
        // dedicated `Thread`s (NOT `DispatchQueue.global()`) so they never
        // compete for the bounded GCD worker pool — under full-suite
        // parallel load (3600+ tests) the shared pool gets saturated and the
        // peer handshakes would starve each other into a 15 s timeout. Each
        // busy-spin also `sched_yield()`s on would-block so a co-scheduled
        // peer thread can make progress instead of being spun out.

        // Server handshakes (proxy-client side + fake-upstream side).
        for serverSSL in [proxyClientSSL, testUpstreamSSL] {
            handshakeGroup.enter()
            Thread.detachNewThread {
                var st = SSLHandshake(serverSSL)
                while st == errSSLWouldBlock { sched_yield(); st = SSLHandshake(serverSSL) }
                if st != errSecSuccess { markFail() }
                handshakeGroup.leave()
            }
        }
        // Client handshakes (test-client side + proxy-upstream side) — each
        // breaks on server-auth to run the TEST-CA trust eval.
        for clientSSL in [testClientSSL, proxyUpstreamSSL] {
            handshakeGroup.enter()
            Thread.detachNewThread {
                var st = SSLHandshake(clientSSL)
                while st == errSSLWouldBlock || st == errSSLPeerAuthCompleted {
                    if st == errSSLPeerAuthCompleted { evalTrust(clientSSL) }
                    else { sched_yield() }
                    st = SSLHandshake(clientSSL)
                }
                if st != errSecSuccess { markFail() }
                handshakeGroup.leave()
            }
        }
        // Generous handshake budget — 30 s tolerates a saturated CI box; the
        // happy path completes in well under a second.
        let handshakeJoined = handshakeGroup.wait(timeout: .now() + 30) == .success

        // --- Run pipeBidirectional on a dedicated thread. clientSSL is the
        //     proxy-side SERVER ctx; upstreamSSL is the proxy-side CLIENT
        //     ctx. ---
        let outcomeBox = OutcomeBox()
        let pipeDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            let outcome = MITMUpstreamVerify.pipeBidirectional(
                clientSSL: proxyClientSSL,
                clientFD: proxyClientFD,
                upstreamSSL: proxyUpstreamSSL,
                upstreamFD: proxyUpstreamFD,
                validatedHost: host,
                bodyDenyEvaluator: evaluator,
                onInnerBodyExcerpt: callback
            )
            outcomeBox.set(outcome)
            pipeDone.signal()
        }

        // --- TEST-CLIENT writes the inner request over the client TLS leg
        //     so the rebind peek reads it. ---
        clientRequest.withUnsafeBytes { raw in
            var sent = 0
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            while sent < clientRequest.count {
                var n = 0
                let st = SSLWrite(testClientSSL, base.advanced(by: sent), clientRequest.count - sent, &n)
                sent += n
                if st == errSSLWouldBlock { continue }
                if st != errSecSuccess { break }
            }
        }

        // --- FAKE UPSTREAM reads whatever pipeBidirectional replays /
        //     forwards. On a body-deny the upstream gets ZERO bytes and the
        //     read returns EOF once the pipe tears down; on a clean allow we
        //     read the replayed head. We read on a background thread with a
        //     bounded budget so a deny (no bytes) does not hang. ---
        let upstreamReceived = UpstreamReader()
        let readDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 4096)
            // Read until EOF / error / a small idle budget elapses (the
            // pipe closes the upstream leg when it returns).
            var idleBudget = 30
            while idleBudget > 0 {
                var got = 0
                let st = buf.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                    SSLRead(testUpstreamSSL, ptr.baseAddress!, ptr.count, &got)
                }
                if got > 0 {
                    upstreamReceived.append(Array(buf[0..<got]))
                    idleBudget = 30
                    continue
                }
                if st == errSSLClosedGraceful || st == errSSLClosedNoNotify { break }
                if st == errSSLWouldBlock {
                    idleBudget -= 1
                    usleep(10_000)
                    continue
                }
                // Any terminal status → stop.
                break
            }
            readDone.signal()
        }

        // Give the pipe a moment to process the request, then close the
        // client leg from the test side so pipeBidirectional sees client
        // EOF (clientDone). On the ALLOW path the pipe also reads from the
        // upstream leg until EOF — so we let the fake-upstream reader drain
        // the replayed head, then close the upstream side so the proxy's
        // `upstreamSSL` read returns EOF (upstreamDone) and the pipe
        // completes via `.upstreamCompleted` instead of grinding the
        // would-block budget. On the DENY path the pipe returns before the
        // drive loop, so these closes are simply teardown.
        usleep(200_000)
        _ = SSLClose(testClientSSL)
        Darwin.shutdown(testClientFD, SHUT_WR)

        // Let the upstream reader settle (it breaks on its idle budget once
        // the replayed head — if any — is drained), then close the
        // fake-upstream side so the pipe's upstream leg reaches EOF.
        _ = readDone.wait(timeout: .now() + 5)
        _ = SSLClose(testUpstreamSSL)
        Darwin.shutdown(testUpstreamFD, SHUT_WR)

        let pipeJoined = pipeDone.wait(timeout: .now() + 30) == .success

        // Teardown.
        _ = SSLClose(proxyClientSSL)
        _ = SSLClose(proxyUpstreamSSL)
        [proxyClientFD, testClientFD, proxyUpstreamFD, testUpstreamFD].forEach { Darwin.close($0) }
        withExtendedLifetime([proxyClientCtx, testClientCtx, proxyUpstreamCtx, testUpstreamCtx]) {}

        okBox.lock(); let hsOK = handshakesOK && handshakeJoined; okBox.unlock()
        return PipeResult(
            outcome: outcomeBox.get() ?? .upstreamIOError(-1),
            upstreamReceived: upstreamReceived.data,
            pipeJoined: pipeJoined,
            handshakesOK: hsOK
        )
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _v: MITMTermination.UpstreamOutcome?
        func set(_ v: MITMTermination.UpstreamOutcome) { lock.lock(); _v = v; lock.unlock() }
        func get() -> MITMTermination.UpstreamOutcome? { lock.lock(); defer { lock.unlock() }; return _v }
    }

    private final class UpstreamReader: @unchecked Sendable {
        private let lock = NSLock()
        private var _bytes: [UInt8] = []
        func append(_ b: [UInt8]) { lock.lock(); _bytes.append(contentsOf: b); lock.unlock() }
        var data: Data { lock.lock(); defer { lock.unlock() }; return Data(_bytes) }
    }

    // Shared fixture builder.
    private func mintIdentity() async throws -> (SecIdentity, SecCertificate, String, String) {
        let (paths, dir) = tempPaths()
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let host = "api.example.com"
        let leaf = try await ca.leaf(forHost: host)
        let caCert = try await ca.caCertificate()
        let identity = try MITMCertificateAuthority.loadIdentity(from: leaf.pkcs12)
        return (identity, caCert, host, dir)
    }

    // MARK: - Allspaw deny coverage + Carmack P2-B + ruleId verbatim + exactly-once

    /// Allspaw P2 + Carmack P2-B + P3 ruleId-verbatim + exactly-once: a
    /// stubbed evaluator returning a canned operator deny makes
    /// pipeBidirectional return `.bodyDeny(ruleId:)` carrying the operator's
    /// ruleId VERBATIM, ZERO bytes reach the upstream, the evaluator was
    /// actually invoked (proving the live call site is wired), and the
    /// `onInnerBodyExcerpt` callback fired EXACTLY ONCE.
    @Test("LIVE deny: evaluator deny → .bodyDeny(operatorRuleId), ZERO upstream bytes, evaluator invoked, callback fires exactly once")
    func livePipeBodyDenyZeroUpstreamBytes() async throws {
        let (identity, caCert, host, dir) = try await mintIdentity()
        defer { cleanup(dir) }

        let evaluator = RecordingEvaluator(
            verdict: EgressEvaluation(decision: .deny, ruleId: "operator-body-deny-42"))
        let recorder = CallbackRecorder()
        let request = Data("POST /v1/exec HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\n\r\n{\"command\":\"TRIPWIRE\"}".utf8)

        let result = Self.runPipe(
            host: host, serverIdentity: identity, caCert: caCert,
            clientRequest: request, evaluator: evaluator,
            callback: { recorder.record($0, $1) })

        #expect(result.handshakesOK, "both TLS legs must complete their handshakes")
        #expect(result.pipeJoined, "pipeBidirectional must return (no hang)")

        // THE load-bearing assertion: live outcome is .bodyDeny carrying the
        // operator's ruleId VERBATIM (Allspaw P3 round-trip).
        switch result.outcome {
        case .bodyDeny(let ruleId):
            #expect(ruleId == "operator-body-deny-42",
                    "LIVE .bodyDeny must carry the operator's ruleId verbatim, got \(ruleId)")
        default:
            Issue.record("expected LIVE .bodyDeny outcome from pipeBidirectional, got \(result.outcome)")
        }

        // ZERO bytes upstream — the deny aborted the forward BEFORE the
        // head-replay write.
        #expect(result.upstreamReceived.isEmpty,
                "FAIL-CLOSED: a body-deny must forward ZERO bytes upstream, got \(result.upstreamReceived.count) bytes")

        // Carmack P2-B: the evaluator was ACTUALLY invoked by the live call
        // site (not a structurally-dead seam).
        #expect(evaluator.calls.count == 1,
                "pipeBidirectional must invoke the injected evaluator exactly once, got \(evaluator.calls.count)")
        if let call = evaluator.calls.first {
            #expect(call.host == host,
                    "evaluator must observe the validated SNI/CONNECT host, got \(call.host)")
            #expect(call.method == "POST", "evaluator must observe method POST, got \(call.method ?? "nil")")
            #expect(call.path == "/v1/exec", "evaluator must observe path /v1/exec, got \(call.path ?? "nil")")
            #expect(call.bodyExcerpt?.contains("TRIPWIRE") == true,
                    "evaluator must observe the redacted body containing TRIPWIRE, got \(call.bodyExcerpt ?? "nil")")
        }

        // Carmack P2-C / Allspaw exactly-once: the audit callback fired
        // EXACTLY ONCE (and BEFORE the deny — it sees the body).
        #expect(recorder.fires.count == 1,
                "onInnerBodyExcerpt must fire EXACTLY ONCE on the .allow rebind arm even when the body is denied, got \(recorder.fires.count)")
        if let fire = recorder.fires.first {
            #expect(fire.0 != nil, "callback must receive the captured body Data on a body-bearing request")
            #expect(fire.1 == .captured,
                    "a fully-captured small body classifies as .captured, got \(fire.1)")
        }
    }

    // MARK: - Allspaw default-deny coverage + Carmack P3-A (sentinel)

    /// Allspaw P2 + Carmack P3-A: a stubbed evaluator returning the
    /// `default-deny` SENTINEL (decision == .deny, ruleId == "default-deny")
    /// must NOT body-deny — the head-replay PROCEEDS and the fake upstream
    /// receives the replayed request HEAD. This pins the string-literal
    /// sentinel comparison at the live call site: a request-dimension MISS
    /// (no operator rule matched) falls through to allow because host-level
    /// was already allowed up-arc.
    @Test("LIVE default-deny sentinel: .deny+'default-deny' does NOT body-deny — head-replay proceeds, upstream receives the request")
    func livePipeDefaultDenySentinelProceeds() async throws {
        let (identity, caCert, host, dir) = try await mintIdentity()
        defer { cleanup(dir) }

        // The default-deny sentinel: decision == .deny but ruleId is the
        // reserved "default-deny" string. The call site MUST treat this as
        // fall-through, NOT a body-deny.
        let evaluator = RecordingEvaluator(verdict: EgressEvaluation.defaultDeny)
        let recorder = CallbackRecorder()
        let requestStr = "POST /v1/exec HTTP/1.1\r\nHost: \(host)\r\n\r\n{\"ok\":1}"
        let request = Data(requestStr.utf8)

        let result = Self.runPipe(
            host: host, serverIdentity: identity, caCert: caCert,
            clientRequest: request, evaluator: evaluator,
            callback: { recorder.record($0, $1) })

        #expect(result.handshakesOK, "both TLS legs must complete their handshakes")
        #expect(result.pipeJoined, "pipeBidirectional must return (no hang)")

        // NOT a body-deny — the outcome is the clean pipe completion.
        if case .bodyDeny(let r) = result.outcome {
            Issue.record("default-deny sentinel must NOT body-deny — got .bodyDeny(\(r))")
        }
        #expect(result.outcome == .upstreamCompleted,
                "default-deny fall-through must run the pipe to completion, got \(result.outcome)")

        // Head-replay PROCEEDED: the fake upstream saw the request HEAD
        // bytes (proving the deny was NOT taken).
        let received = String(data: result.upstreamReceived, encoding: .utf8) ?? ""
        #expect(received.contains("POST /v1/exec"),
                "head-replay must proceed on a default-deny sentinel — upstream must receive the request line, got \(received.debugDescription)")
        #expect(received.contains("Host: \(host)"),
                "upstream must receive the full replayed HEAD including the Host header")

        // The evaluator was still invoked once (the call site evaluated,
        // then chose fall-through).
        #expect(evaluator.calls.count == 1,
                "evaluator must be invoked once even on a fall-through, got \(evaluator.calls.count)")
        // Callback still fires exactly once.
        #expect(recorder.fires.count == 1,
                "callback must fire exactly once, got \(recorder.fires.count)")
    }

    // MARK: - Carmack P2-A — fail-CLOSED on HEAD parse failure

    /// Carmack P2-A: the `mitm_inner_head_parse_failed` fail-CLOSED branch
    /// END-TO-END through pipeBidirectional. We feed a request whose Host
    /// header validates (the rebind peek's `.allow` arm fires) but whose
    /// full HEAD then fails `parseInnerHTTPHead` — a malformed request line.
    /// The live call site must return `.bodyDeny(ruleId:
    /// "mitm_inner_head_parse_failed")` and forward ZERO bytes upstream.
    ///
    /// To reach the parse-failed branch we need the rebind peek to ALLOW
    /// (Host matches, looks like HTTP/1.x, terminator present) while
    /// `parseInnerHTTPHead` returns nil. A request line with only TWO
    /// tokens after a recognized method satisfies `looksLikeHTTP1`
    /// (first token is a known method) AND carries a valid Host header, but
    /// `parseInnerHTTPHead` rejects the 2-token request line.
    @Test("LIVE fail-CLOSED: Host validates but HEAD parse fails → .bodyDeny(mitm_inner_head_parse_failed), ZERO upstream bytes")
    func livePipeHeadParseFailedFailsClosed() async throws {
        let (identity, caCert, host, dir) = try await mintIdentity()
        defer { cleanup(dir) }

        // First token "POST" → looksLikeHTTP1 true. Host header matches →
        // rebind .allow. But the request line has only 2 tokens
        // ("POST /only-two") so parseInnerHTTPHead returns nil → fail-CLOSED.
        let evaluator = RecordingEvaluator(
            verdict: EgressEvaluation(decision: .allow, ruleId: "should-not-be-consulted"))
        let recorder = CallbackRecorder()
        let requestStr = "POST /only-two\r\nHost: \(host)\r\n\r\nbodybytes"
        let request = Data(requestStr.utf8)

        // Sanity: the rebind decision MUST be .allow (so we reach the
        // parse-failed branch, not an earlier rebind reject), and
        // parseInnerHTTPHead MUST return nil on this buffer.
        let buf = Array(requestStr.utf8)
        let decision = MITMInnerHostRebind.decide(headBytes: buf, validatedHost: host)
        if case .allow = decision { /* good */ } else {
            Issue.record("fixture invariant: rebind must .allow this request so the parse-failed branch is reachable, got \(decision)")
        }
        #expect(MITMUpstreamVerify.parseInnerHTTPHead(buf) == nil,
                "fixture invariant: parseInnerHTTPHead must return nil on the 2-token request line")

        let result = Self.runPipe(
            host: host, serverIdentity: identity, caCert: caCert,
            clientRequest: request, evaluator: evaluator,
            callback: { recorder.record($0, $1) })

        #expect(result.handshakesOK, "both TLS legs must complete their handshakes")
        #expect(result.pipeJoined, "pipeBidirectional must return (no hang)")

        switch result.outcome {
        case .bodyDeny(let ruleId):
            #expect(ruleId == "mitm_inner_head_parse_failed",
                    "HEAD parse failure must fail-CLOSED with the stable ruleId, got \(ruleId)")
        default:
            Issue.record("expected .bodyDeny(mitm_inner_head_parse_failed), got \(result.outcome)")
        }

        // ZERO bytes upstream — fail-CLOSED refuses to forward ambiguous bytes.
        #expect(result.upstreamReceived.isEmpty,
                "fail-CLOSED: a HEAD-parse failure must forward ZERO bytes upstream, got \(result.upstreamReceived.count) bytes")

        // The evaluator must NEVER be consulted — the parse failure
        // short-circuits BEFORE the evaluator is reached.
        #expect(evaluator.calls.isEmpty,
                "the evaluator must NOT be consulted when HEAD parse fails (parse-failed short-circuits first), got \(evaluator.calls.count) calls")

        // The audit callback STILL fires once on the .allow arm (it runs
        // before the parse-failed branch — the operator can see what
        // crossed the tunnel even on a fail-CLOSED).
        #expect(recorder.fires.count == 1,
                "onInnerBodyExcerpt must fire exactly once before the parse-failed branch, got \(recorder.fires.count)")
    }
}
