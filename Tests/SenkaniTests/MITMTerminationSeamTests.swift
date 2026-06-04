import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-2b-ii — server-side MITM termination seam tests.
///
/// Two MUST-PASS panel invariants land here:
///
///   1. **ClientHello-not-double-consumed.** `handleConnect` destructively
///      `read()`s the ClientHello into the peek buffer for SNI extraction.
///      The `MITMTermination` prepend-buffer `SSLReadFunc` must drain
///      those bytes back into the SecureTransport state machine BEFORE
///      reading the fd — otherwise the server would see a truncated
///      ClientHello and the handshake would fail.
///   2. **Termination round-trip behind the flag.** Real TLS client
///      connects through the listener with the flag ON; assert the
///      handshake completes with the t1d-1 leaf and the sentinel
///      plaintext from the server is decrypted by the client. With the
///      flag OFF the same path runs through the opaque tunnel.
///
/// We also pin a third invariant the spec calls "non-blocking IO fail-
/// CLOSED": when the handshake state machine sees an unrecoverable IO
/// error, the seam returns a fail-CLOSED outcome and does NOT silently
/// fall back to an opaque tunnel.
@Suite("MITM-termination seam (T.1d-2b-ii)")
struct MITMTerminationSeamTests {

    // MARK: - Temp-CA helpers (mirror TLSTerminationSpikeTests / MITMCertificateAuthorityTests)

    private func tempPaths() -> (MITMCertificateAuthority.Paths, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-term-ii-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - Test 1 — ClientHello not double-consumed after peek

    /// Hazard #1 from the t1d-2b panel: `handleConnect` destructively
    /// reads the first ~4 KB of the ClientHello off the client fd to
    /// extract the SNI, then HANDS THE TERMINATION SEAM the rest of the
    /// fd. If we naively wired SecureTransport straight to the fd, the
    /// already-consumed bytes would be lost — the server would see a
    /// truncated handshake and `SSLHandshake` would fail with
    /// `errSSLProtocol` or similar.
    ///
    /// The fix lives in `MITMTermination.Context.prepend` + the custom
    /// `sslReadCallback` which drains the peek buffer FIRST. This test
    /// proves that fix end-to-end:
    ///   • a real SecureTransport TLS client writes a real ClientHello;
    ///   • the test driver pre-consumes ALL of those bytes off the
    ///     server-side fd (simulating the SNI peek);
    ///   • `runTermination` is then asked to terminate using only the
    ///     server fd + the pre-consumed peek buffer;
    ///   • the handshake completes (`Outcome.terminated`), the client
    ///     reads the sentinel plaintext byte-for-byte, and the peer
    ///     cert byte-matches the minted t1d-1 leaf.
    @Test("prepend-buffer SSLReadFunc drains the peek so the ClientHello is not double-consumed")
    func clientHelloNotDoubleConsumedAfterPeek() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }

        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let host = "peek-replay.example.com"
        let leaf = try await ca.leaf(forHost: host)
        let caCert = try await ca.caCertificate()
        let mintedLeafDER = leaf.certificateDER

        // The synchronous driver does the socketpair + thread-join
        // dance off the async test body so the DispatchSemaphore wait
        // is legal. See TLSTerminationSpikeTests for the same split.
        let driveResult = Self.runDoubleConsumeSeam(
            host: host,
            caCert: caCert,
            leafPKCS12: leaf.pkcs12
        )

        #expect(driveResult.joined, "client thread did not finish — probable hang in the seam")
        #expect(driveResult.peekStartsWithHandshakeByte,
                "first peek byte is not a TLS handshake record (0x16) — test assumption violated")

        let outcome = driveResult.outcome

        // 1. The handshake MUST succeed. If `MITMTermination` failed
        //    to drain the prepend buffer, the server would see a
        //    truncated ClientHello and this would fail with
        //    `.handshakeFailed`.
        #expect(outcome == .terminated,
                "termination did not reach .terminated — outcome=\(outcome)")

        // 2. The client must have completed its handshake AND read
        //    the full sentinel plaintext — that proves the server
        //    presented something the SecureTransport state machine
        //    recognized AND that the plaintext side is wired.
        #expect(driveResult.client.handshakeStatus == errSecSuccess,
                "client handshake status was \(driveResult.client.handshakeStatus)")
        let sentinel = Data("SENKANI-MITM-TERMINATED\n".utf8)
        #expect(driveResult.client.sentinel == sentinel,
                "client did not read the sentinel back — got \(driveResult.client.sentinel.count) bytes")

        // 3. The peer cert byte-equals the minted leaf — proves the
        //    server actually loaded the t1d-1 identity (not a fresh
        //    self-signed cert).
        let peerLeaf = try #require(driveResult.client.peerLeafDER,
                                    "client did not extract a peer leaf cert")
        #expect(peerLeaf == mintedLeafDER,
                "peer leaf bytes do not match minted leaf — server presented the wrong identity")

        // 4. The client must have actually evaluated trust against
        //    the test CA — guards against a vacuous pass.
        #expect(driveResult.client.trustEvaluated,
                "client trust evaluation never ran — anchor pin not exercised")
    }

    /// Synchronous driver for the double-consume test. The semaphore
    /// join is unavailable from async contexts; this helper isolates
    /// the join so the test body itself stays async-clean.
    private struct DoubleConsumeResult {
        let outcome: MITMTermination.Outcome
        let client: ClientHelper.Result
        let joined: Bool
        let peekStartsWithHandshakeByte: Bool
    }

    private static func runDoubleConsumeSeam(
        host: String,
        caCert: SecCertificate,
        leafPKCS12: Data
    ) -> DoubleConsumeResult {
        let (serverFD, clientFD) = makeSocketPair()
        defer { Darwin.close(serverFD); Darwin.close(clientFD) }

        let clientCtx = ClientHelper.IOContext(clientFD)
        let clientResult = ClientHelper.Result()
        let clientDone = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            ClientHelper.driveTLSClient(
                host: host,
                anchorCA: caCert,
                ctx: clientCtx,
                result: clientResult,
                sentinelLength: Data("SENKANI-MITM-TERMINATED\n".utf8).count
            )
            clientDone.signal()
        }

        // Simulate handleConnect's destructive peek.
        var peek = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            Darwin.read(serverFD, ptr.baseAddress, ptr.count)
        }
        if n > 0 {
            peek.append(contentsOf: buf[0..<n])
        }
        let firstIsHandshake = (peek.first == 0x16)

        // Hand the pre-peeked bytes to the seam.
        let outcome = MITMTermination.runTermination(
            fd: serverFD,
            peek: peek,
            leafPKCS12: leafPKCS12
        )

        let joined = clientDone.wait(timeout: .now() + 15) == .success
        return DoubleConsumeResult(
            outcome: outcome,
            client: clientResult,
            joined: joined,
            peekStartsWithHandshakeByte: firstIsHandshake
        )
    }

    // MARK: - Test 2 — Termination round-trip behind the flag (end-to-end)

    /// Hazard #2 from the t1d-2b panel + the load-bearing acceptance
    /// bullet: flag ON terminates the client TLS session with the
    /// t1d-1 leaf and immediately routes plaintext to a re-originated
    /// VERIFIED upstream leg (child iii). The listener-level test
    /// asserts the audit-row contract for the new path:
    ///   - flag-ON + leaf-provider wired,
    ///   - the upstream is unreachable (no TLS server is bound at
    ///     127.0.0.1:443 in CI),
    ///   - so the seam fails-CLOSED on upstream connect → deny audit
    ///     row with ruleId `mitm_upstream_unreachable`. Critically NOT
    ///     a fall-through to the opaque tunnel (no `allow-loopback`
    ///     row), and NOT a `mitm_upstream_cert_rejected` (we never
    ///     reached the cert eval).
    ///
    /// The server-side TLS handshake itself (peek-drain, leaf
    /// presentation, plaintext channel) is exercised end-to-end by
    /// `clientHelloNotDoubleConsumedAfterPeek` above (which calls
    /// `runTermination` directly with the sentinel path). The
    /// upstream-verify positive path lives in
    /// `MITMUpstreamVerifySeamTests`.
    @Test("flag-ON CONNECT + upstream unreachable → fail-CLOSED via mitm_upstream_unreachable, never falls through to opaque tunnel")
    func terminationRoundTripBehindFlag() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }

        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let host = "127.0.0.1"  // the CONNECT host — normalized identical to SNI
        let leaf = try await ca.leaf(forHost: host)
        let caCert = try await ca.caCertificate()
        let mintedLeafDER = leaf.certificateDER

        // Capture the PKCS#12 by host. Nonisolated by construction —
        // we read it on the listener queue.
        let leafPKCS12 = leaf.pkcs12
        let provider: (String) -> Data? = { askedHost in
            askedHost == host ? leafPKCS12 : nil
        }

        // Pick an unreachable port for the upstream CONNECT target.
        // 127.0.0.1:1 is closed in CI; the upstream connector will
        // return nil, the seam will fail-CLOSED via
        // `.upstreamUnreachable`. The CONNECT line itself uses 443 to
        // keep the SNI-normalization path identical to production —
        // but production's port is the connector's port, and the
        // default connector dials parsed.port, so we must redirect via
        // a LoopbackStubConnector pointed at a port we know is closed.
        let db = tempDB()
        let listener = EgressListener(
            policy: EgressPolicy(engines: [.default: EgressRuleEngine(rules: [
                EgressRule(id: "allow-loopback", pattern: host, mode: .exact, decision: .allow)
            ])]),
            database: db,
            config: .init(port: 0, writePortFile: false, portFilePath: "", mitmTermination: true),
            upstreamConnector: ClosedPortConnector(),
            mitmLeafProvider: provider,
            mitmTrustEvaluator: nil
        )
        try listener.start()
        defer { listener.stop() }

        // --- Open a TCP connection to the listener and issue CONNECT. ---
        let proxyFD = connectToLocalhost(port: listener.port)
        try #require(proxyFD != nil)
        let proxy = proxyFD!
        defer { Darwin.close(proxy) }

        let connectReq = "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n"
        #expect(writeAllToFD(proxy, Data(connectReq.utf8)))

        // Drain the 200 reply head.
        let okResp = readHTTPHead(proxy)
        let okStr = String(data: okResp, encoding: .utf8) ?? ""
        #expect(okStr.contains("200 Connection Established"))

        // --- Drive a real SecureTransport TLS client over the proxy fd.
        //     The server-side handshake will succeed (the seam loads the
        //     t1d-1 leaf and runs the handshake), then immediately try
        //     to connect to the upstream via the stubbed connector,
        //     which returns nil → fail-CLOSED on .upstreamUnreachable. ---
        let clientCtx = ClientHelper.IOContext(proxy)
        let clientResult = ClientHelper.Result()
        ClientHelper.driveTLSClient(
            host: host,
            anchorCA: caCert,
            ctx: clientCtx,
            result: clientResult,
            sentinelLength: 1  // 1 byte is enough — we don't expect any
        )

        // 1. Handshake completed — proves the server-side termination
        //    seam took the t1d-1 leaf and the SecureTransport client
        //    is happy with it.
        #expect(clientResult.handshakeStatus == errSecSuccess,
                "TLS client handshake failed: \(clientResult.handshakeStatus)")

        // 2. Peer cert byte-equality — proves the right identity was
        //    presented (NOT a fresh self-signed cert).
        let peerLeaf = try #require(clientResult.peerLeafDER)
        #expect(peerLeaf == mintedLeafDER,
                "server presented the wrong cert — t1d-1 leaf not used")

        // 3. Audit row records the DENY under the new
        //    `mitm_upstream_unreachable` ruleId — the load-bearing
        //    fail-CLOSED contract for the upstream-verify path.
        //    Critically NOT `allow-loopback` (no opaque-tunnel
        //    fallback) and NOT `mitm_upstream_cert_rejected` (we
        //    never reached the cert eval).
        let row = waitForRow(db: db)
        try #require(row != nil)
        #expect(row!.decision == .deny,
                "fail-CLOSED expected when upstream is unreachable, got decision=\(row!.decision)")
        #expect(row!.method == "CONNECT")
        #expect(row!.ruleId == "mitm_upstream_unreachable",
                "expected mitm_upstream_unreachable, got: \(row!.ruleId)")
    }

    /// Test-only connector that returns nil so the seam exercises its
    /// `.upstreamUnreachable` branch deterministically — no race on a
    /// closed loopback port, no risk of accidentally dialing a real
    /// upstream from CI.
    private struct ClosedPortConnector: EgressUpstreamConnecting {
        func connect(host: String, port: Int, timeoutSeconds: Int) -> Int32? {
            return nil
        }
    }

    // MARK: - Test 3 — Non-blocking IO fail-CLOSED

    /// The seam MUST NOT silently fall back to an opaque tunnel on a
    /// TLS error — that would be a fail-OPEN bypass of the security
    /// control the flag turns ON.
    ///
    /// We exercise this by handing `runTermination` a peek buffer
    /// containing junk bytes (not a valid TLS record) + a socketpair
    /// fd whose far end is closed BEFORE the handshake can drain any
    /// real ClientHello. The handshake state machine MUST return a
    /// non-success status; the seam MUST surface that as a non-
    /// `.terminated` outcome.
    @Test("seam returns fail-CLOSED on handshake error — no silent tunnel fallback")
    func nonBlockingIOFailsClosedOnHandshakeError() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let leaf = try await ca.leaf(forHost: "fail.example.com")

        let (serverFD, clientFD) = Self.makeSocketPair()
        defer { Darwin.close(serverFD) }
        // Close the client end IMMEDIATELY so server-side reads see EOF.
        Darwin.close(clientFD)

        // Hand the seam junk bytes that don't make a valid handshake.
        // Even after they're consumed, the next fd read returns 0
        // (EOF) → errSSLClosedGraceful → SSLHandshake fails.
        let junk = Data([0x16, 0x03, 0x03, 0x00, 0x04, 0xff, 0xff, 0xff, 0xff])

        let outcome = MITMTermination.runTermination(
            fd: serverFD,
            peek: junk,
            leafPKCS12: leaf.pkcs12
        )

        // The load-bearing assertion: a non-`.terminated` outcome.
        // We do NOT pin a specific error code — different macOS
        // versions can pick different OSStatus values for a malformed
        // ClientHello + premature EOF. What matters is that the seam
        // SIGNALS FAILURE rather than silently succeeding (or worse,
        // falling through to an opaque tunnel).
        switch outcome {
        case .terminated:
            Issue.record("FAIL-CLOSED VIOLATION: junk + EOF reached .terminated — seam silently accepted invalid TLS")
        case .handshakeFailed, .ioError, .wouldBlockBudgetExhausted,
             .contextCreateFailed, .identityLoadFailed, .identitySetFailed,
             .sentinelWriteBudgetExhausted,
             .upstreamCompleted, .upstreamUnreachable, .upstreamHandshakeFailed,
             .upstreamCertRejected, .upstreamIOError,
             .upstreamWouldBlockBudgetExhausted, .upstreamWriteBudgetExhausted:
            // Any non-.terminated outcome is correct fail-CLOSED
            // behavior. (The .upstream* variants are unreachable from
            // the sentinel-mode `runTermination` overload exercised
            // here, but listing them keeps the switch exhaustive
            // against the shared `Outcome` enum.)
            break
        }
    }

    // MARK: - TLS-client helper (shared by tests 1 + 2)

    /// SecureTransport-based TLS client used by the seam tests. Lives
    /// inside the test target — production code is the SERVER side of
    /// the MITM (this seam) plus child (iii)'s upstream-verified leg
    /// (separate file). This client uses its own IO callbacks because
    /// `SSLConnectionRef` is a single-pointer ABI and we don't want to
    /// share the production server context type.
    enum ClientHelper {
        final class IOContext {
            let fd: Int32
            init(_ fd: Int32) { self.fd = fd }
        }

        final class Result: @unchecked Sendable {
            var handshakeStatus: OSStatus = errSSLWouldBlock
            var trustEvaluated: Bool = false
            var peerLeafDER: Data?
            var sentinel: Data = Data()
        }

        /// Blocking-read callback. Loops on short reads, retries
        /// `EINTR`, returns errSSLWouldBlock on EAGAIN (the client
        /// driver below treats that the same as the server seam does).
        static let readFunc: SSLReadFunc = { connection, data, dataLength in
            let ctx = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
            let want = dataLength.pointee
            var got = 0
            let base = data.assumingMemoryBound(to: UInt8.self)
            while got < want {
                let n = Darwin.read(ctx.fd, base + got, want - got)
                if n > 0 { got += n; continue }
                if n == 0 {
                    dataLength.pointee = got
                    return errSSLClosedGraceful
                }
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

        static let writeFunc: SSLWriteFunc = { connection, data, dataLength in
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

        /// Drive a TLS client side: build the context, run the
        /// handshake, evaluate trust against `anchorCA`, capture the
        /// peer leaf DER, then SSLRead exactly `sentinelLength` bytes
        /// of plaintext.
        static func driveTLSClient(
            host: String,
            anchorCA: SecCertificate,
            ctx: IOContext,
            result: Result,
            sentinelLength: Int
        ) {
            guard let ssl = SSLCreateContext(nil, .clientSide, .streamType) else {
                result.handshakeStatus = errSSLInternal
                return
            }
            _ = SSLSetIOFuncs(ssl, readFunc, writeFunc)
            _ = SSLSetConnection(ssl, Unmanaged.passUnretained(ctx).toOpaque())
            _ = SSLSetProtocolVersionMin(ssl, .tlsProtocol12)
            _ = SSLSetPeerDomainName(ssl, host, host.utf8.count)
            _ = SSLSetSessionOption(ssl, .breakOnServerAuth, true)

            var st = SSLHandshake(ssl)
            while st == errSSLWouldBlock || st == errSSLPeerAuthCompleted {
                if st == errSSLPeerAuthCompleted {
                    var peerTrust: SecTrust?
                    if SSLCopyPeerTrust(ssl, &peerTrust) == errSecSuccess, let trust = peerTrust {
                        _ = SecTrustSetAnchorCertificates(trust, [anchorCA] as CFArray)
                        _ = SecTrustSetAnchorCertificatesOnly(trust, true)
                        var trustErr: CFError?
                        result.trustEvaluated = SecTrustEvaluateWithError(trust, &trustErr)
                        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                           let leafCert = chain.first {
                            result.peerLeafDER = SecCertificateCopyData(leafCert) as Data
                        }
                    }
                }
                st = SSLHandshake(ssl)
            }
            result.handshakeStatus = st
            if st != errSecSuccess { return }

            // Read the sentinel plaintext the server wrote post-handshake.
            var read = Data()
            let bufCap = 256
            var buf = [UInt8](repeating: 0, count: bufCap)
            while read.count < sentinelLength {
                var processed = 0
                let rst = buf.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                    guard let base = ptr.baseAddress else { return errSSLInternal }
                    return SSLRead(ssl, base, min(bufCap, sentinelLength - read.count), &processed)
                }
                if processed > 0 {
                    read.append(contentsOf: buf[0..<processed])
                }
                if rst == errSecSuccess { continue }
                if rst == errSSLWouldBlock { continue }
                // Any other status — including errSSLClosedGraceful
                // after we've drained everything available — ends the
                // loop.
                break
            }
            result.sentinel = read
        }
    }

    // MARK: - DB helper (mirror EgressProxyTests)

    private func tempDB() -> SessionDatabase {
        let dir = NSTemporaryDirectory() + "senkani-mitm-term-ii-db-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return SessionDatabase(path: dir + "senkani.db")
    }
}
