import Testing
import Foundation
@testable import Core

/// P2-12: SocketAuthToken tests. Each test uses its own temp file path via
/// the `at:` parameter — parallel-safe, no process-env races.
@Suite("SocketAuthToken")
struct SocketAuthTokenTests {

    private static func makeTempPath() -> String {
        NSTemporaryDirectory() + "senkani-socket-auth-test-\(UUID().uuidString).token"
    }

    @Test func generateWritesTokenFileWithExactly0600() throws {
        let path = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let hex = try SocketAuthToken.generate(at: path)
        #expect(hex.count == 64, "32 bytes → 64 hex chars")
        #expect(hex.allSatisfy { $0.isHexDigit }, "token must be valid hex")

        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let posix = attrs[.posixPermissions] as? NSNumber
        #expect((posix?.uint16Value ?? 0) & 0o777 == 0o600, "token file must be 0600")
    }

    @Test func loadReturnsTokenWrittenByGenerate() throws {
        let path = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let written = try SocketAuthToken.generate(at: path)
        let loaded = SocketAuthToken.load(at: path)
        #expect(loaded == written)
    }

    @Test func loadReturnsNilWhenFileMissing() {
        let path = Self.makeTempPath()
        #expect(SocketAuthToken.load(at: path) == nil)
    }

    @Test func loadRejectsWorldReadableToken() throws {
        let path = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try SocketAuthToken.generate(at: path)
        _ = chmod(path, 0o644)
        #expect(SocketAuthToken.load(at: path) == nil,
                "refuse to use a token whose file permissions are not 0600")
    }

    @Test func generateRotatesOnSecondCall() throws {
        let path = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let first = try SocketAuthToken.generate(at: path)
        let second = try SocketAuthToken.generate(at: path)
        #expect(first != second, "every call produces a fresh token")
    }

    @Test func clearRemovesTokenFile() throws {
        let path = Self.makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        _ = try SocketAuthToken.generate(at: path)
        #expect(SocketAuthToken.load(at: path) != nil)
        SocketAuthToken.clear(at: path)
        #expect(SocketAuthToken.load(at: path) == nil)
    }

    // MARK: - Handshake frame encode/decode

    @Test func handshakeFrameBuildsWithLengthPrefix() throws {
        let token = "deadbeef"
        let frame = try #require(SocketAuthToken.handshakeFrame(token: token))
        #expect(frame.count >= 5)

        let length = frame.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }
        let decodedLen = Int(UInt32(bigEndian: length))
        #expect(decodedLen == frame.count - 4, "length prefix matches body size")

        let body = frame.dropFirst(4)
        let obj = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let handshake = obj?["handshake"] as? [String: Any]
        #expect(handshake?["token"] as? String == token)
    }

    @Test func handshakeFrameNilOnEmptyToken() {
        #expect(SocketAuthToken.handshakeFrame(token: "") == nil)
    }

    @Test func validateHandshakePayloadAcceptsMatch() {
        let token = "abcd1234"
        let body = "{\"handshake\":{\"token\":\"\(token)\"}}"
        #expect(SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: token))
    }

    @Test func validateHandshakePayloadRejectsMismatch() {
        let body = "{\"handshake\":{\"token\":\"wrong\"}}"
        #expect(!SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: "right"))
    }

    @Test func validateHandshakePayloadRejectsMissingHandshakeKey() {
        let body = "{\"other\":{\"token\":\"abc\"}}"
        #expect(!SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: "abc"))
    }

    @Test func validateHandshakePayloadRejectsMissingToken() {
        let body = "{\"handshake\":{}}"
        #expect(!SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: "abc"))
    }

    @Test func validateHandshakePayloadRejectsOversize() {
        let padding = String(repeating: "x", count: SocketAuthToken.maxFrameBytes + 1)
        let body = "{\"handshake\":{\"token\":\"abc\",\"pad\":\"\(padding)\"}}"
        #expect(!SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: "abc"))
    }

    @Test func validateHandshakePayloadRejectsMalformedJSON() {
        let body = "not json {"
        #expect(!SocketAuthToken.validateHandshakePayload(Data(body.utf8), expectedToken: "abc"))
    }

    // MARK: - Constant-time comparison

    @Test func constantTimeEqualsSameLengthMatch() {
        #expect(SocketAuthToken.constantTimeEquals("abc123", "abc123"))
    }

    @Test func constantTimeEqualsSameLengthMismatch() {
        #expect(!SocketAuthToken.constantTimeEquals("abc123", "abc124"))
    }

    @Test func constantTimeEqualsDifferentLength() {
        #expect(!SocketAuthToken.constantTimeEquals("abc", "abcd"))
    }
}
