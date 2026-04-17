import Testing
import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import MCPServer
@testable import Core

/// Bach G8 — coverage for PaneControlTool's client-side handshake.
///
/// The pane socket uses the same length-prefixed handshake contract as
/// the hook + MCP sockets. PaneControlTool.handle() is a large function
/// (~140 LOC of socket setup + JSON encode/decode) so the handshake send
/// was extracted into `writeHandshakeFrame(fd:tokenPath:)` for direct
/// coverage. These tests pin three invariants:
///
///   1. No token file → no-op on the wire, returns true (legacy-compatible).
///   2. Token file present → emits a frame byte-identical to
///      `SocketAuthToken.handshakeFrame(token:)` (the canonical format
///      used by server-side verification).
///   3. Server-side `SocketAuthToken.readAndValidate` accepts it round-trip.
@Suite("PaneControlTool handshake (Bach G8)")
struct PaneControlHandshakeTests {

    // MARK: - Helpers

    private static func makeTempTokenPath() -> String {
        NSTemporaryDirectory() + "senkani-panectl-test-\(UUID().uuidString).token"
    }

    private static func writeToken(_ token: String, to path: String, mode: mode_t = 0o600) throws {
        FileManager.default.createFile(atPath: path, contents: Data(token.utf8))
        _ = chmod(path, mode)
    }

    private static func makeSocketPair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let rc = fds.withUnsafeMutableBufferPointer { buf in
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress)
        }
        precondition(rc == 0, "socketpair failed: \(rc)")
        return (fds[0], fds[1])
    }

    // MARK: - No-op path

    @Test func noTokenFileIsNoOpAndReturnsTrue() {
        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        let ok = PaneControlTool.writeHandshakeFrame(
            fd: client, tokenPath: Self.makeTempTokenPath())
        #expect(ok, "no token file → must return true so legacy clients stay compatible")

        var pfd = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        let polled = poll(&pfd, 1, 50)
        #expect(polled == 0, "no bytes should be readable when handshake is a no-op")
    }

    @Test func worldReadableTokenIsTreatedAsAbsent() throws {
        // SocketAuthToken.load rejects files with permissions > 0600. The
        // helper must inherit that rejection — if it didn't, an attacker
        // who planted a 0644 token would cause the client to leak it.
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("leaked", to: path, mode: 0o644)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        let ok = PaneControlTool.writeHandshakeFrame(fd: client, tokenPath: path)
        #expect(ok, "insecure token → treat as no-op, return true")

        var pfd = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        let polled = poll(&pfd, 1, 50)
        #expect(polled == 0, "insecure token must NOT be sent on the wire")
    }

    // MARK: - Wire format

    @Test func writesFrameByteIdenticalToSocketAuthToken() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let token = "0123456789abcdef0123456789abcdef"
        try Self.writeToken(token, to: path, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(PaneControlTool.writeHandshakeFrame(fd: client, tokenPath: path))

        let canonical = try #require(SocketAuthToken.handshakeFrame(token: token))
        var buf = [UInt8](repeating: 0, count: canonical.count + 16)
        let n = Darwin.read(server, &buf, buf.count)
        #expect(n == canonical.count,
                "frame length must match SocketAuthToken.handshakeFrame")
        let received = Data(buf.prefix(n))
        #expect(received == canonical,
                "pane client must write the canonical frame byte-for-byte — any drift breaks mutual auth")
    }

    // MARK: - Server-side round-trip

    @Test func serverValidatorAcceptsGoodHandshake() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let token = "pane-control-test-token"
        try Self.writeToken(token, to: path, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(PaneControlTool.writeHandshakeFrame(fd: client, tokenPath: path))

        let accepted = SocketAuthToken.readAndValidate(
            fd: server, expectedToken: token, timeoutMs: 2000)
        #expect(accepted,
                "production server-side verifier must accept the client-sent frame end-to-end")
    }

    @Test func serverValidatorRejectsMismatchedToken() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("client-side", to: path, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(PaneControlTool.writeHandshakeFrame(fd: client, tokenPath: path))

        let accepted = SocketAuthToken.readAndValidate(
            fd: server, expectedToken: "server-side", timeoutMs: 2000)
        #expect(!accepted, "mismatched tokens must fail the constant-time compare")
    }

    @Test func returnsFalseOnClosedPeer() throws {
        // When the pane-socket peer closes the connection before we write,
        // the helper must return false so the caller can surface an error
        // rather than swallow the lost handshake.
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("any-token", to: path, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        Darwin.close(server)   // kill the peer before the write
        defer { Darwin.close(client) }

        // Suppress SIGPIPE for this process for the duration of the test.
        // write(2) on a broken pipe would kill the test runner otherwise.
        var act = sigaction()
        act.__sigaction_u.__sa_handler = SIG_IGN
        sigaction(SIGPIPE, &act, nil)

        let ok = PaneControlTool.writeHandshakeFrame(fd: client, tokenPath: path)
        #expect(!ok, "short-write from EPIPE must propagate as false")
    }
}
