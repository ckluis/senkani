import Foundation

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// P2-12: Shared-secret token for senkani Unix-domain-socket authentication.
///
/// Threat model: any process running as the same UID can connect to
/// `~/.senkani/{mcp,hook,pane}.sock` today and invoke `senkani_exec` with
/// arbitrary shell commands — including prompt-injected LLM subagents and
/// compromised npm postinstall scripts. A shared-secret token file raises
/// the bar from "ambient UID access" to "must read ~/.senkani/.token". Not a
/// cure-all (same-UID can read the file), but it blocks the prompt-injection
/// pathway that is the realistic attack since the MCP era began.
///
/// Behavior:
/// - `SENKANI_SOCKET_AUTH=on` enables token generation + handshake enforcement.
///   Unset/off (**default this release**) → token file is not written and the
///   socket listeners accept connections without a handshake (backward compat).
/// - On server start, the token is (re)generated: 32 random bytes → 64 hex
///   characters, written to `~/.senkani/.token` with mode 0600. Rotates on
///   every startup per Cavoukian's "never reuse across sessions" note.
/// - Clients read the token file and send a handshake frame as the FIRST
///   length-prefixed frame on every connection. Missing or wrong token →
///   server closes the connection.
/// - Frame size cap (1 KB) prevents DoS via oversize handshakes.
public enum SocketAuthToken {

    /// Default token file path under the user's senkani config dir.
    public static var defaultTokenPath: String {
        NSHomeDirectory() + "/.senkani/.token"
    }

    /// Back-compat accessor — the default path.
    public static var tokenPath: String { defaultTokenPath }

    /// Oversize-handshake cap. Handshake JSON is ~90 bytes; 1 KB is generous.
    public static let maxFrameBytes: Int = 1024

    /// Whether socket auth is enabled by the env flag. Evaluated each call —
    /// cheap env read, and lets users toggle without restarting tests.
    public static var isEnabled: Bool {
        let raw = ProcessInfo.processInfo.environment["SENKANI_SOCKET_AUTH"]?.lowercased() ?? ""
        return raw == "on" || raw == "1" || raw == "true" || raw == "yes"
    }

    /// Generate a new token, overwrite the file at `path` (default:
    /// `defaultTokenPath`), and return the fresh value. Callers treat failure
    /// as "auth unavailable" — log and proceed un-auth'd. The `path` param
    /// supports parallel-safe testing: every test writes to its own file so
    /// they don't race on shared process state.
    @discardableResult
    public static func generate(at path: String? = nil) throws -> String {
        let target = path ?? defaultTokenPath
        let dir = (target as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard rc == errSecSuccess else {
            throw NSError(domain: "SocketAuthToken", code: Int(rc), userInfo: [
                NSLocalizedDescriptionKey: "SecRandomCopyBytes failed with OSStatus \(rc)"
            ])
        }

        let hex = bytes.map { String(format: "%02x", $0) }.joined()

        // Write + chmod. chmod(0o600) lands immediately after write — the
        // same-UID threat model does not benefit from tighter ordering.
        let data = Data(hex.utf8)
        try data.write(to: URL(fileURLWithPath: target), options: [.atomic])
        _ = Darwin.chmod(target, 0o600)

        return hex
    }

    /// Read the current token if one exists at `path` (default:
    /// `defaultTokenPath`) and has acceptable permissions. Returns nil when
    /// the file is absent or world/group-readable (defensive — refuse an
    /// insecure token rather than use it).
    public static func load(at path: String? = nil) -> String? {
        let target = path ?? defaultTokenPath
        guard FileManager.default.fileExists(atPath: target) else { return nil }

        // Permissions check — reject anything beyond 0600.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
           let posix = attrs[.posixPermissions] as? NSNumber,
           (posix.uint16Value & 0o177) != 0 {
            return nil
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: target)),
              let hex = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
              !hex.isEmpty
        else { return nil }

        return hex
    }

    /// Remove the token file — called on clean server shutdown.
    public static func clear(at path: String? = nil) {
        _ = Darwin.unlink(path ?? defaultTokenPath)
    }

    // MARK: - Handshake frame construction and validation

    /// Build a length-prefixed handshake frame carrying `token`. Clients
    /// write this to the socket as the first frame immediately after connect.
    /// Length prefix is 4 bytes big-endian. Returns nil if token is empty.
    public static func handshakeFrame(token: String) -> Data? {
        guard !token.isEmpty else { return nil }
        let body = "{\"handshake\":{\"token\":\"\(token)\"}}"
        let payload = Data(body.utf8)
        guard payload.count <= maxFrameBytes else { return nil }
        var length = UInt32(payload.count).bigEndian
        var frame = Data()
        frame.append(Data(bytes: &length, count: 4))
        frame.append(payload)
        return frame
    }

    /// Parse and validate a decoded payload (what the server reads after the
    /// length prefix). Returns true iff the payload matches the expected
    /// handshake shape and token.
    public static func validateHandshakePayload(_ payload: Data, expectedToken: String) -> Bool {
        guard payload.count <= maxFrameBytes,
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let handshake = obj["handshake"] as? [String: Any],
              let received = handshake["token"] as? String,
              !received.isEmpty
        else { return false }
        return constantTimeEquals(received, expectedToken)
    }

    /// Constant-time string comparison — avoids timing-oracle leaks if an
    /// attacker could measure compare latency. Both strings must be equal
    /// length to return true.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
