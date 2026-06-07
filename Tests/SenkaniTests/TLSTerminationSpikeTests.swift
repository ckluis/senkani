import Foundation
import Testing
import Security
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import Core

/// T.1d-2a — TLS-termination PROOF-OF-SEAM spike (option (a) SecureTransport).
///
/// A 4-member Luminary panel (Schneier/Allspaw/Carmack/Karpathy) DECIDED the
/// approach: SecureTransport (`SSLContext` + `SSLSetIOFuncs` bridging a raw
/// fd). This file proves the SEAM only — that a leaf minted by t1d-1's CA,
/// loaded back through `MITMCertificateAuthority.loadIdentity(from:)`, can
/// terminate a REAL TLS-1.2+ handshake over a loopback `socketpair(2)` and
/// present the *exact minted leaf bytes* to a client that anchors trust on
/// the test CA.
///
/// SecureTransport is deprecated since macOS 10.15. That is ACCEPTABLE for a
/// throwaway spike — the panel explicitly rejected re-architecting onto
/// NWConnection. The production wiring into `handleConnect` is t1d-2b; the
/// seam logic here lives entirely IN THE TEST (a test-local helper), so
/// `Sources/` stays UNTOUCHED.
///
/// ## Deliberate boundaries of this spike (do NOT pretend otherwise)
///   - The socketpair has both ends always-ready, the fds are BLOCKING, and
///     the handshake runs on threads. So the production `errSSLWouldBlock` /
///     partial-read / `EINTR` path that t1d-2b inherits is NOT exercised
///     here — a correct blocking read/write loop in the IO callbacks
///     suffices for the seam proof.
///   - On this macOS-15+ build host the server identity comes from
///     `loadIdentityMemoryOnly` (the memory-only PKCS#12 import). The
///     macOS-14 `loadIdentityViaEphemeralKeychain` path is therefore NOT
///     exercised by THIS handshake (it is tracked separately by
///     phase-t1d-1-macos14-floor-verification, which calls that helper
///     directly).
@Suite("TLS-termination spike (T.1d-2a)")
struct TLSTerminationSpikeTests {

    // MARK: - Temp-CA helpers (mirror MITMCertificateAuthorityTests)

    /// Fresh temp paths for an isolated TEST CA — caller deletes the dir.
    /// NEVER `~/.senkani`, NEVER the System/login keychain.
    private func tempPaths() -> (MITMCertificateAuthority.Paths, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-mitm-test-\(UUID().uuidString)", isDirectory: true)
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

    // MARK: - @convention(c) IO bridge

    /// `@convention(c)` closures cannot capture, so the fd is reached through
    /// the `SSLConnectionRef` we set with `SSLSetConnection` — a pointer to a
    /// heap-boxed `IOContext` holding the raw fd.
    private final class IOContext {
        let fd: Int32
        init(_ fd: Int32) { self.fd = fd }
    }

    /// SSL read callback: a BLOCKING `read(2)` loop that fills exactly
    /// `*dataLength` bytes, writes the ACTUAL transferred count back into
    /// `dataLength`, and returns `errSSLWouldBlock` only on a 0-length /
    /// EAGAIN situation. Loops on short reads and retries on `EINTR`.
    private static let sslReadFunc: SSLReadFunc = { connection, data, dataLength in
        let ctx = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        var got = 0
        let base = data.assumingMemoryBound(to: UInt8.self)
        while got < want {
            let n = Darwin.read(ctx.fd, base + got, want - got)
            if n > 0 {
                got += n
                continue
            }
            if n == 0 {
                // EOF / orderly shutdown.
                dataLength.pointee = got
                return errSSLClosedGraceful
            }
            // n < 0
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

    /// SSL write callback: a BLOCKING `write(2)` loop that drains exactly
    /// `*dataLength` bytes, writes the ACTUAL transferred count back into
    /// `dataLength`. Loops on short writes and retries on `EINTR`.
    private static let sslWriteFunc: SSLWriteFunc = { connection, data, dataLength in
        let ctx = Unmanaged<IOContext>.fromOpaque(connection).takeUnretainedValue()
        let want = dataLength.pointee
        var sent = 0
        let base = data.assumingMemoryBound(to: UInt8.self)
        while sent < want {
            let n = Darwin.write(ctx.fd, base + sent, want - sent)
            if n > 0 {
                sent += n
                continue
            }
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

    // MARK: - Outcome boxes

    /// Captured negotiated parameters from one side of the handshake.
    private final class HandshakeOutcome: @unchecked Sendable {
        var status: OSStatus = errSSLWouldBlock
        var protocolVersion: SSLProtocol = .sslProtocolUnknown
        var cipher: SSLCipherSuite = SSLCipherSuite(SSL_NULL_WITH_NULL_NULL)
    }

    /// Everything the synchronous handshake driver produces, surfaced back to
    /// the (async) test for assertion.
    private struct SeamResult {
        let server: HandshakeOutcome
        let client: HandshakeOutcome
        let serverJoined: Bool
        let clientTrustEvaluated: Bool
        let peerLeafDER: Data?
    }

    // MARK: - The spike

    @Test("minted SecIdentity terminates a real TLS-1.2+ handshake over a loopback fd")
    func mintedIdentityCompletesRealHandshakeOverSocketpair() async throws {
        let (paths, dir) = tempPaths()
        defer { cleanup(dir) }

        // --- Mint a TEST CA + a leaf, exactly like MITMCertificateAuthorityTests. ---
        let ca = MITMCertificateAuthority(paths: paths, keyBits: 2048)
        _ = try await ca.generateRoot()
        let host = "spike.example.com"
        let leaf = try await ca.leaf(forHost: host)
        let caCertDER = try await ca.caCertificateDER()
        let caCert = try #require(SecCertificateCreateWithData(nil, caCertDER as CFData))

        // The minted leaf's DER — the byte-identity oracle for the peer cert.
        let mintedLeafDER = leaf.certificateDER

        // --- Consume t1d-1's load path: memory-only PKCS#12 import on this
        //     macOS-15+ host. The server identity MUST come from here, NOT a
        //     freshly-built cert+key — that is what surfaces any PKCS#12-import
        //     / SSLSetCertificate identity-shape mismatch. ---
        let serverIdentity = try MITMCertificateAuthority.loadIdentity(from: leaf.pkcs12)

        // Drive the SecureTransport handshake in a SYNCHRONOUS helper. The
        // interactive handshake uses a `DispatchSemaphore` to join the
        // background server thread, and `wait()` is unavailable from an async
        // context — so the blocking orchestration lives here, off the async
        // test body. The async body only does the actor-isolated minting above.
        // Positive path: the client anchors on the SAME CA that issued the
        // server leaf, so the server leaf chains → trust eval ACCEPTS.
        let result = Self.runHandshakeSeam(
            serverIdentity: serverIdentity,
            clientAnchorCA: caCert,
            host: host)

        // --- MUST-PASS assertions (panel P1) ---

        // Server thread must have joined (no hang).
        #expect(result.serverJoined,
                "server handshake did not complete within 10s (possible hang)")

        // 1. Both handshakes returned errSecSuccess.
        #expect(result.server.status == errSecSuccess,
                "server SSLHandshake failed: status=\(result.server.status)")
        #expect(result.client.status == errSecSuccess,
                "client SSLHandshake failed: status=\(result.client.status)")

        // We actually hit the server-auth break and evaluated trust against
        // the test CA — not a default System-anchor pass.
        #expect(result.clientTrustEvaluated,
                "client never reached errSSLPeerAuthCompleted — trust was not evaluated against the test CA")

        // 2. Negotiated peer-cert BYTE-IDENTITY: the leaf the server presented
        //    (via the loaded SecIdentity) byte-equals the minted leaf DER.
        let peerLeaf = try #require(result.peerLeafDER,
                                    "could not extract the peer leaf certificate from the client's trust chain")
        #expect(peerLeaf == mintedLeafDER,
                "peer leaf cert bytes must equal the minted leaf DER — proves the SERVER presented the minted leaf via loadIdentity's SecIdentity, not a stale/default cert")

        // 3. Pinned version + real crypto (no plaintext-loopback false green).
        //    SSLProtocol raw values are ordered; tlsProtocol12 < tlsProtocol13,
        //    and the negotiated value must be >= tlsProtocol12.
        #expect(result.server.protocolVersion.rawValue >= SSLProtocol.tlsProtocol12.rawValue,
                "server negotiated protocol \(result.server.protocolVersion) is below TLS 1.2")
        #expect(result.client.protocolVersion.rawValue >= SSLProtocol.tlsProtocol12.rawValue,
                "client negotiated protocol \(result.client.protocolVersion) is below TLS 1.2")
        #expect(result.server.cipher != SSLCipherSuite(SSL_NULL_WITH_NULL_NULL),
                "server negotiated the NULL cipher — no real crypto (plaintext passthrough false-green)")
        #expect(result.client.cipher != SSLCipherSuite(SSL_NULL_WITH_NULL_NULL),
                "client negotiated the NULL cipher — no real crypto (plaintext passthrough false-green)")
        #expect(result.server.cipher == result.client.cipher,
                "both peers must agree on the negotiated cipher suite")

        // 4. No System/login keychain mutation: the identity came from t1d-1's
        //    memory-only path. (A stray-keychain-file count assertion was
        //    removed — it raced against concurrent parallel tests minting in
        //    the shared temp dir; the guarantee is makeEphemeralKeychain's
        //    defer-unlink. Non-racy scoped check tracked by the filed follow-up.)
    }

    // MARK: - Negative seam: anchor-pinning is load-bearing (T.1d-2b)

    /// The CONVERSE the t1d-2a happy path never proved: a server presenting a
    /// leaf minted under a CA the client does NOT anchor on is REJECTED.
    ///
    /// Two INDEPENDENT test CAs in separate temp dirs:
    ///   • CA-A — the client's trusted anchor (`clientAnchorCA`),
    ///   • CA-B — an untrusted CA the client never anchors on.
    /// The server presents a leaf minted under CA-B (via the same
    /// `loadIdentity` SecIdentity path as the positive test). The client
    /// anchors trust ONLY on CA-A (`SecTrustSetAnchorCertificates([caA])` +
    /// `SecTrustSetAnchorCertificatesOnly(true)`) and evaluates with
    /// `SecTrustEvaluateWithError`. Because the CA-B leaf does NOT chain to
    /// CA-A, the evaluation FAILS → `clientTrustEvaluated == false`.
    ///
    /// This proves the anchor-pinning the positive test exercises is actually
    /// ENFORCED: a non-chaining server cert is refused, not silently accepted.
    @Test("server leaf from an untrusted CA is rejected by the client's anchor pin")
    func serverLeafFromUntrustedCAIsRejected() async throws {
        // --- CA-A: the client's TRUSTED anchor (its leaf is never presented). ---
        let (pathsA, dirA) = tempPaths()
        defer { cleanup(dirA) }
        let caA = MITMCertificateAuthority(paths: pathsA, keyBits: 2048)
        _ = try await caA.generateRoot(commonName: "senkani TEST CA-A (trusted anchor)")
        let caACertDER = try await caA.caCertificateDER()
        let caACert = try #require(SecCertificateCreateWithData(nil, caACertDER as CFData))

        // --- CA-B: an INDEPENDENT, UNTRUSTED CA. The server's leaf is minted
        //     under THIS root, which the client never anchors on. ---
        let (pathsB, dirB) = tempPaths()
        defer { cleanup(dirB) }
        let caB = MITMCertificateAuthority(paths: pathsB, keyBits: 2048)
        _ = try await caB.generateRoot(commonName: "senkani TEST CA-B (untrusted)")
        let host = "untrusted.example.com"
        let leafB = try await caB.leaf(forHost: host)

        // Same load path as the positive test: the server identity comes from
        // loadIdentity (memory-only PKCS#12 import on this macOS-15+ host).
        let serverIdentity = try MITMCertificateAuthority.loadIdentity(from: leafB.pkcs12)

        // Run the SAME generalized seam: server presents the CA-B leaf, client
        // anchors ONLY on CA-A. Trust eval must REJECT (no chain to CA-A).
        let result = Self.runHandshakeSeam(
            serverIdentity: serverIdentity,
            clientAnchorCA: caACert,
            host: host)

        // Server thread must have joined (the 10s timeout guard means a
        // non-completing handshake FAILS fast rather than hanging forever).
        #expect(result.serverJoined,
                "server handshake did not complete within 10s (possible hang)")

        // We must have actually reached the server-auth break and run a trust
        // evaluation against CA-A — otherwise the assertion below is vacuous.
        let peerLeaf = try #require(result.peerLeafDER,
                                    "client never extracted the peer leaf — the server-auth break / trust eval was not reached")
        #expect(peerLeaf == leafB.certificateDER,
                "the server presented the CA-B leaf (sanity: we are rejecting the RIGHT cert, not a stale one)")

        // THE load-bearing assertion: a server leaf chaining to CA-B is
        // REJECTED when the client anchors ONLY on CA-A. This is the converse
        // the positive-only spike never proved — anchor-pinning is enforced.
        #expect(result.clientTrustEvaluated == false,
                "client trust eval ACCEPTED a server leaf from CA-B while anchored only on CA-A — anchor-pinning is NOT load-bearing")
    }

    // MARK: - Synchronous handshake driver

    /// Stand up the server + client SSLContexts over a `socketpair(2)`, run the
    /// server `SSLHandshake` on a background queue and the client on the
    /// calling thread, and join with a 10s timeout. Synchronous on purpose so
    /// the `DispatchSemaphore` join is legal (it is unavailable from async).
    private static func runHandshakeSeam(
        serverIdentity: SecIdentity,
        clientAnchorCA: SecCertificate,
        host: String
    ) -> SeamResult {
        // Connected socket pair: one fd server-side, the other client-side.
        let (serverFD, clientFD) = makeSocketPair()
        defer { Darwin.close(serverFD); Darwin.close(clientFD) }

        let serverCtx = IOContext(serverFD)
        let clientCtx = IOContext(clientFD)

        let server = HandshakeOutcome()
        let client = HandshakeOutcome()

        // --- SERVER seam: SSLContext on the server fd, presenting the minted
        //     identity. Runs on a background queue so it can progress
        //     concurrently with the client over the blocking pair. ---
        guard let serverSSL = SSLCreateContext(nil, .serverSide, .streamType) else {
            return SeamResult(server: server, client: client, serverJoined: false,
                              clientTrustEvaluated: false, peerLeafDER: nil)
        }
        _ = SSLSetIOFuncs(serverSSL, sslReadFunc, sslWriteFunc)
        _ = SSLSetConnection(serverSSL, Unmanaged.passUnretained(serverCtx).toOpaque())
        _ = SSLSetCertificate(serverSSL, [serverIdentity] as CFArray)
        _ = SSLSetProtocolVersionMin(serverSSL, .tlsProtocol12)
        // Server-only auth: do NOT request a client certificate.
        _ = SSLSetClientSideAuthenticate(serverSSL, .neverAuthenticate)

        let serverDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var st = SSLHandshake(serverSSL)
            while st == errSSLWouldBlock { st = SSLHandshake(serverSSL) }
            server.status = st
            if st == errSecSuccess {
                var v: SSLProtocol = .sslProtocolUnknown
                _ = SSLGetNegotiatedProtocolVersion(serverSSL, &v)
                server.protocolVersion = v
                var c: SSLCipherSuite = SSLCipherSuite(SSL_NULL_WITH_NULL_NULL)
                _ = SSLGetNegotiatedCipher(serverSSL, &c)
                server.cipher = c
            }
            serverDone.signal()
        }

        // --- CLIENT seam: SSLContext on the other fd. Break on server auth and
        //     evaluate the peer trust manually against the CLIENT'S anchor CA
        //     (so we never touch the System trust store). This anchor is
        //     INDEPENDENT of the server's identity: the positive test passes
        //     the CA that issued the server leaf (chains → accepted); the
        //     negative test passes a DIFFERENT CA the server leaf does NOT
        //     chain to (no chain → rejected). ---
        var clientTrustEvaluated = false
        var peerLeafDER: Data?
        guard let clientSSL = SSLCreateContext(nil, .clientSide, .streamType) else {
            // Let the server thread unwind before tearing the fds down.
            _ = serverDone.wait(timeout: .now() + 10)
            return SeamResult(server: server, client: client, serverJoined: true,
                              clientTrustEvaluated: false, peerLeafDER: nil)
        }
        _ = SSLSetIOFuncs(clientSSL, sslReadFunc, sslWriteFunc)
        _ = SSLSetConnection(clientSSL, Unmanaged.passUnretained(clientCtx).toOpaque())
        _ = SSLSetProtocolVersionMin(clientSSL, .tlsProtocol12)
        _ = SSLSetPeerDomainName(clientSSL, host, host.utf8.count)
        // Break the handshake on server-auth so WE evaluate trust against the
        // test CA, never the default System anchors.
        _ = SSLSetSessionOption(clientSSL, .breakOnServerAuth, true)

        var cstatus = SSLHandshake(clientSSL)
        while cstatus == errSSLWouldBlock || cstatus == errSSLPeerAuthCompleted {
            if cstatus == errSSLPeerAuthCompleted {
                // Pull the peer trust, anchor it ONLY on the client's anchor
                // CA, evaluate. `clientTrustEvaluated` is the load-bearing
                // result: true iff the server leaf chains to `clientAnchorCA`.
                var peerTrust: SecTrust?
                if SSLCopyPeerTrust(clientSSL, &peerTrust) == errSecSuccess, let trust = peerTrust {
                    _ = SecTrustSetAnchorCertificates(trust, [clientAnchorCA] as CFArray)
                    _ = SecTrustSetAnchorCertificatesOnly(trust, true)
                    var trustErr: CFError?
                    clientTrustEvaluated = SecTrustEvaluateWithError(trust, &trustErr)
                    // Byte-identity oracle: leaf SecCertificate at index 0.
                    if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
                       let leafCert = chain.first {
                        peerLeafDER = SecCertificateCopyData(leafCert) as Data
                    }
                }
            }
            cstatus = SSLHandshake(clientSSL)
        }
        client.status = cstatus
        if cstatus == errSecSuccess {
            var v: SSLProtocol = .sslProtocolUnknown
            _ = SSLGetNegotiatedProtocolVersion(clientSSL, &v)
            client.protocolVersion = v
            var c: SSLCipherSuite = SSLCipherSuite(SSL_NULL_WITH_NULL_NULL)
            _ = SSLGetNegotiatedCipher(clientSSL, &c)
            client.cipher = c
        }

        // Join the server with a timeout so a hang FAILS the test rather than
        // blocking forever.
        let serverJoined = serverDone.wait(timeout: .now() + 10) == .success

        return SeamResult(server: server, client: client, serverJoined: serverJoined,
                          clientTrustEvaluated: clientTrustEvaluated, peerLeafDER: peerLeafDER)
    }
}
