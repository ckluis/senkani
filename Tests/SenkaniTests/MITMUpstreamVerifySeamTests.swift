import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-2b-iii — upstream-verify seam tests.
///
/// Load-bearing P0: a server presenting a leaf NOT in the System
/// trust store MUST be rejected by `MITMUpstreamVerify.connectAndVerify`
/// when called with the production `defaultEvaluate` evaluator.
///
/// The test stands up a real TLS server on a loopback TCP port whose
/// identity is a fresh TEST CA leaf (NEVER added to System trust). The
/// `connectAndVerify` client opens a TCP connection, runs the TLS
/// handshake, hits the `breakOnServerAuth` callback, evaluates trust
/// against System anchors → `SecTrustEvaluateWithError` returns false
/// → the result is `.upstreamCertRejected`. Critically, NO plaintext
/// is forwarded to the would-be-trusted upstream because the connect
/// closes the fd before returning.
///
/// The positive path uses the test-only evaluator injection seam: we
/// build a TEST-CA evaluator that anchors trust on the freshly-minted
/// CA and run the same `connectAndVerify` against the same TLS server
/// — this proves the connect-and-handshake plumbing works without
/// having to register a System anchor.
@Suite("MITM upstream-verify seam (T.1d-2b-iii)")
struct MITMUpstreamVerifySeamTests {

    // MARK: - Temp-CA helpers (mirror MITMTerminationSeamTests)

    private func tempPaths() -> (MITMCertificateAuthority.Paths, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-upstream-iii-\(UUID().uuidString)", isDirectory: true)
        let paths = MITMCertificateAuthority.Paths(
            publicCertPEM: dir.appendingPathComponent("egress-ca.pem").path,
            privateKeyPEM: dir.appendingPathComponent("egress-ca.key").path
        )
        return (paths, dir.path)
    }

    private func cleanup(_ dir: String) {
        try? FileManager.default.removeItem(atPath: dir)
    }

    // MARK: - Loopback TLS test server

    /// One-shot TLS server: binds a loopback TCP port, accepts ONE
    /// connection on a background queue, runs the server-side TLS
    /// handshake using `MITMTermination.runTermination` (which loads
    /// the supplied PKCS#12 + presents the leaf), then closes. Used by
    /// the bad-cert-rejected test to give `connectAndVerify` a real
    /// TLS peer with a self-signed-test-CA leaf.
    private final class LoopbackTLSServer {
        let port: Int
        private let listenFD: Int32
        private let done = DispatchSemaphore(value: 0)

        init(port: Int, listenFD: Int32) {
            self.port = port
            self.listenFD = listenFD
        }

        static func start(leafPKCS12: Data) -> LoopbackTLSServer? {
            let lfd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard lfd >= 0 else { return nil }
            var yes: Int32 = 1
            _ = Darwin.setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = 0
            addr.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
            let br = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.bind(lfd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard br == 0 else { Darwin.close(lfd); return nil }
            guard Darwin.listen(lfd, 1) == 0 else { Darwin.close(lfd); return nil }
            // Recover the actual port.
            var bound = sockaddr_in()
            var blen = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    Darwin.getsockname(lfd, sa, &blen)
                }
            }
            let port = Int(UInt16(bigEndian: bound.sin_port))
            let server = LoopbackTLSServer(port: port, listenFD: lfd)
            // Accept + drive handshake on a background queue.
            DispatchQueue.global().async {
                var ca = sockaddr_in()
                var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let cfd = withUnsafeMutablePointer(to: &ca) { ptr -> Int32 in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        Darwin.accept(lfd, sa, &clen)
                    }
                }
                if cfd < 0 {
                    server.done.signal()
                    return
                }
                defer { Darwin.close(cfd) }
                // Drive a server-side TLS handshake using the existing
                // termination seam. We hand it an empty peek buffer so
                // it reads the ClientHello directly off the fd. The
                // sentinel write may or may not complete — the client
                // side is going to fail trust eval and close — either
                // way the seam is fail-CLOSED on its end too.
                _ = MITMTermination.runTermination(
                    fd: cfd,
                    peek: Data(),
                    leafPKCS12: leafPKCS12
                )
                server.done.signal()
            }
            return server
        }

        func stop() {
            if listenFD >= 0 { Darwin.close(listenFD) }
            _ = done.wait(timeout: .now() + 5)
        }
    }

    // MARK: - Test 1 — Bad upstream cert is rejected (THE P0)

    /// THE P0 negative test: a TLS server presenting a self-signed
    /// TEST-CA leaf (NOT in System anchors) is rejected by
    /// `MITMUpstreamVerify.connectAndVerify` using the production
    /// `defaultEvaluate` evaluator. The result is
    /// `.upstreamCertRejected(_)`, the upstream fd is closed before
    /// return, and the reason string is sanitized (no raw cert bytes).
    @Test("self-signed upstream leaf NOT in System trust → .upstreamCertRejected, fail-CLOSED")
    func badUpstreamCertRejected() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        // Use `localhost` so the cert's DNS SAN (the CA mints
        // `subjectAltNameDNS(host)`) properly binds via
        // SSLSetPeerDomainName. The TLS server still binds 127.0.0.1
        // — connect target is by IP, peer-domain-name is by hostname,
        // and the trust-eval hostname check uses the latter.
        let leaf = try await ca.leaf(forHost: "localhost")
        let server = try #require(LoopbackTLSServer.start(leafPKCS12: leaf.pkcs12))
        defer { server.stop() }

        // Production evaluator: System anchors. The TEST CA is NOT in
        // System anchors → trust eval MUST fail → fail-CLOSED.
        let result = MITMUpstreamVerify.connectAndVerify(
            host: "localhost",
            port: server.port,
            timeoutSeconds: 5
            // evaluator + connector use production defaults.
        )

        switch result {
        case .succeeded:
            Issue.record("FAIL-CLOSED VIOLATION: connectAndVerify accepted a self-signed leaf NOT in System trust — anchor verification is not load-bearing")
        case .failed(let outcome):
            // Must be the cert-rejected variant specifically — NOT a
            // handshake error or IO error.
            switch outcome {
            case .upstreamCertRejected(let reason):
                // Reason must be a short classification string, never
                // raw cert bytes / hostnames embedded.
                #expect(!reason.isEmpty, "reason string is empty")
                #expect(reason.count < 200,
                        "reason string too long (\(reason.count) chars) — possible info leak: \(reason)")
                // Sanitization assertion: should not contain raw DER
                // markers or hostname-shaped substrings beyond the
                // tiny enum-string vocabulary.
                #expect(!reason.contains("CERTIFICATE-----"),
                        "reason string leaks PEM content: \(reason)")
                #expect(!reason.contains("127.0.0.1"),
                        "reason string leaks upstream hostname: \(reason)")
            default:
                Issue.record("expected .upstreamCertRejected, got \(outcome)")
            }
        }
    }

    // MARK: - Test 2 — Positive path via test-only evaluator injection seam

    /// Positive sanity: the same `connectAndVerify` shape DOES succeed
    /// when the evaluator anchors trust on the TEST CA. This proves
    /// the connect+handshake plumbing is wired correctly — i.e. the
    /// failure in test 1 is anchor-pinning enforcement, not "the
    /// client never reached the trust eval at all".
    @Test("TEST-CA anchored evaluator → handshake succeeds (positive sanity)")
    func validUpstreamCertAcceptedWithTestAnchor() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let leaf = try await ca.leaf(forHost: "localhost")
        let caCertDER = try await ca.caCertificateDER()
        let caCert = try #require(SecCertificateCreateWithData(nil, caCertDER as CFData))
        let server = try #require(LoopbackTLSServer.start(leafPKCS12: leaf.pkcs12))
        defer { server.stop() }

        // Test-only evaluator that pins trust on the TEST CA. This is
        // INVERSE to production posture — only here so we can prove the
        // connect+handshake plumbing in isolation.
        let testEvaluator: MITMUpstreamVerify.TrustEvaluator = { trust in
            _ = SecTrustSetAnchorCertificates(trust, [caCert] as CFArray)
            _ = SecTrustSetAnchorCertificatesOnly(trust, true)
            var cfErr: CFError?
            if SecTrustEvaluateWithError(trust, &cfErr) {
                return .accepted
            }
            return .rejected(reason: "chain validation failed")
        }

        let result = MITMUpstreamVerify.connectAndVerify(
            host: "localhost",
            port: server.port,
            timeoutSeconds: 5,
            evaluator: testEvaluator
        )

        switch result {
        case .succeeded(let handle):
            // Close handle to clean up the fd.
            Darwin.close(handle.fd)
        case .failed(let outcome):
            Issue.record("expected .succeeded with test anchor, got \(outcome)")
        }
    }

    // MARK: - Test 3 — Sanitization of CFError mapping

    /// Direct unit test on the sanitization helper: nil CFError →
    /// generic classification; unknown error code → generic; well-known
    /// hostname code → `"hostname mismatch"`. We don't construct real
    /// CFErrors of every code (Security framework owns those values);
    /// we just assert the nil-path classification is the stable
    /// generic string we promised.
    @Test("sanitizedTrustErrorReason on nil CFError returns stable classification string")
    func sanitizedTrustErrorReasonNilPath() async throws {
        let reason = MITMUpstreamVerify.sanitizedTrustErrorReason(nil)
        #expect(reason == "chain validation failed",
                "nil CFError must map to the stable 'chain validation failed' classification, got: \(reason)")
    }

    // MARK: - Test 4 — Carmack r92 P3 — connector injection seam contract

    /// Recording stub: an `EgressUpstreamConnecting` that records the
    /// host/port it was asked to dial and returns a caller-controlled
    /// fd (or nil for the failure path). Used by the connector-seam
    /// tests below to assert `connectAndVerify` actually routes its
    /// `host`/`port` arguments through the seam (and that the nil-fd
    /// outcome surfaces as `.upstreamUnreachable`, not as a silent
    /// fall-through to the default connector).
    private final class RecordingConnector: EgressUpstreamConnecting, @unchecked Sendable {
        struct Call: Sendable {
            let host: String
            let port: Int
            let timeoutSeconds: Int
        }
        private let lock = NSLock()
        private var _calls: [Call] = []
        private let fdToReturn: Int32?
        var calls: [Call] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        init(fdToReturn: Int32?) {
            self.fdToReturn = fdToReturn
        }
        func connect(host: String, port: Int, timeoutSeconds: Int) -> Int32? {
            lock.lock()
            _calls.append(Call(host: host, port: port, timeoutSeconds: timeoutSeconds))
            lock.unlock()
            return fdToReturn
        }
    }

    /// Carmack r92 P3 — connector seam contract: a stub connector
    /// returning nil must surface as `.upstreamUnreachable`, AND the
    /// stub must have observed the exact host/port the caller passed.
    /// This pins the seam at the API contract level so a future
    /// refactor cannot silently fall back to the default connector
    /// (which would dial the real internet from CI).
    @Test("connector seam: stub returning nil → .upstreamUnreachable, stub observed exact host/port")
    func connectorSeamObservesHostPortAndSurfacesUnreachable() async throws {
        let stub = RecordingConnector(fdToReturn: nil)
        let result = MITMUpstreamVerify.connectAndVerify(
            host: "test.example",
            port: 1234,
            timeoutSeconds: 5,
            connector: stub
        )
        // Outcome: nil fd → .upstreamUnreachable, fail-CLOSED.
        switch result {
        case .succeeded:
            Issue.record("FAIL-CLOSED VIOLATION: nil-fd connector return must NOT surface as .succeeded — got success")
        case .failed(let outcome):
            switch outcome {
            case .upstreamUnreachable:
                break  // ✓
            default:
                Issue.record("expected .upstreamUnreachable for nil-fd connector return, got \(outcome)")
            }
        }
        // Contract: the stub MUST have been called exactly once with
        // the caller's host + port (no silent fall-through to the
        // default connector).
        #expect(stub.calls.count == 1,
                "connector seam should be called exactly once; got \(stub.calls.count) calls")
        if let call = stub.calls.first {
            #expect(call.host == "test.example",
                    "connector seam observed wrong host: \(call.host)")
            #expect(call.port == 1234,
                    "connector seam observed wrong port: \(call.port)")
        }
    }
}
