import Testing
import Foundation
#if canImport(Darwin)
import Darwin.POSIX
#endif
@testable import HookRelay
@testable import Core

/// Bach G7 — coverage for HookRelay's inline handshake machinery.
///
/// HookRelay is the zero-dep library target shared by `senkani-hook` (the
/// compiled binary) and the app's `--hook` mode. It reimplements the
/// handshake inline rather than importing `Core.SocketAuthToken` so the
/// binary stays <1 MB with no transitive deps (Lesson #12). That means
/// the two implementations can drift silently — the audit's G7 finding.
///
/// These tests lock in three invariants:
///   1. `loadAuthToken` honors the same permission check as `SocketAuthToken.load`.
///   2. `sendHandshake` writes a frame byte-identical to
///      `SocketAuthToken.handshakeFrame(token:)` — the canonical format.
///   3. A server using `SocketAuthToken.readAndValidate` accepts HookRelay's
///      output round-trip over a connected Unix socket pair.
@Suite("HookRelay handshake (Bach G7)")
struct HookRelayHandshakeTests {

    // MARK: - Helpers

    private static func makeTempTokenPath() -> String {
        NSTemporaryDirectory() + "senkani-hookrelay-test-\(UUID().uuidString).token"
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

    // MARK: - loadAuthToken

    @Test func loadReturnsNilWhenFileMissing() {
        #expect(HookRelay.loadAuthToken(at: Self.makeTempTokenPath()) == nil)
    }

    @Test func loadReturnsTokenWhenFileIs0600() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("abc123deadbeef", to: path, mode: 0o600)
        #expect(HookRelay.loadAuthToken(at: path) == "abc123deadbeef")
    }

    @Test func loadRejectsWorldReadableToken() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("abc123", to: path, mode: 0o644)
        #expect(HookRelay.loadAuthToken(at: path) == nil,
                "HookRelay must match SocketAuthToken's 0600 guard — any wider permission → nil")
    }

    @Test func loadRejectsGroupReadableToken() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("abc123", to: path, mode: 0o640)
        #expect(HookRelay.loadAuthToken(at: path) == nil)
    }

    @Test func loadTrimsWhitespace() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("  abc123\n\n", to: path, mode: 0o600)
        #expect(HookRelay.loadAuthToken(at: path) == "abc123")
    }

    @Test func loadReturnsNilOnEmptyFile() throws {
        let path = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try Self.writeToken("", to: path, mode: 0o600)
        #expect(HookRelay.loadAuthToken(at: path) == nil)
    }

    // MARK: - sendHandshake — no-op path

    @Test func sendHandshakeIsNoOpAndReturnsTrueWhenNoTokenFile() {
        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        let ok = HookRelay.sendHandshake(fd: client, tokenPath: Self.makeTempTokenPath())
        #expect(ok, "no token file → must return true so the caller proceeds un-auth'd")

        // Server side should have nothing queued — a no-op must not
        // write bytes onto the wire (server-side auth is gated separately).
        var pfd = pollfd(fd: server, events: Int16(POLLIN), revents: 0)
        let polled = poll(&pfd, 1, 50)
        #expect(polled == 0, "no bytes should be readable when handshake is a no-op")
    }

    // MARK: - sendHandshake — wire format

    @Test func sendHandshakeWritesFrameByteIdenticalToSocketAuthToken() throws {
        let tokenPath = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: tokenPath) }
        let token = "deadbeef1234"
        try Self.writeToken(token, to: tokenPath, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(HookRelay.sendHandshake(fd: client, tokenPath: tokenPath))

        // Read everything HookRelay wrote.
        let canonical = try #require(SocketAuthToken.handshakeFrame(token: token))
        var buf = [UInt8](repeating: 0, count: canonical.count + 16)
        let n = Darwin.read(server, &buf, buf.count)
        #expect(n == canonical.count,
                "HookRelay frame length (\(n)) must equal SocketAuthToken.handshakeFrame length (\(canonical.count))")

        let received = Data(buf.prefix(n))
        #expect(received == canonical,
                "HookRelay's inline frame must be byte-identical to Core.SocketAuthToken.handshakeFrame")
    }

    @Test func sendHandshakePayloadValidatesAgainstSocketAuthToken() throws {
        let tokenPath = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: tokenPath) }
        let token = "0123456789abcdef"
        try Self.writeToken(token, to: tokenPath, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(HookRelay.sendHandshake(fd: client, tokenPath: tokenPath))

        // Run the server-side verifier that MCP uses in production.
        let accepted = SocketAuthToken.readAndValidate(
            fd: server, expectedToken: token, timeoutMs: 2000)
        #expect(accepted,
                "SocketAuthToken.readAndValidate (server-side verifier) must accept HookRelay's frame end-to-end")
    }

    @Test func sendHandshakeRejectedWhenTokensDiffer() throws {
        let tokenPath = Self.makeTempTokenPath()
        defer { try? FileManager.default.removeItem(atPath: tokenPath) }
        try Self.writeToken("client-token", to: tokenPath, mode: 0o600)

        let (client, server) = Self.makeSocketPair()
        defer { Darwin.close(client); Darwin.close(server) }

        #expect(HookRelay.sendHandshake(fd: client, tokenPath: tokenPath))

        // Server expects a different token — must reject without hanging.
        let accepted = SocketAuthToken.readAndValidate(
            fd: server, expectedToken: "server-token", timeoutMs: 2000)
        #expect(!accepted,
                "token mismatch must fail the server-side validator (constant-time rejection)")
    }
}
