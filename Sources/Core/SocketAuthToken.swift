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
    ///
    /// F6 (Schneier re-audit 2026-04-16): the prior implementation used
    /// `Data.write(.atomic)` followed by `chmod(path, 0o600)`. Between the
    /// `.atomic` rename and the chmod, the final file briefly existed with
    /// umask-default permissions (typically 0644). Closed by writing to a
    /// `.tmp` sibling with explicit mode 0o600 + `fchmod` (bypass umask) +
    /// `rename()`. The final path never exists with wider permissions than
    /// 0o600 — even for the microsecond-wide race window the prior code had.
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
        let data = Data(hex.utf8)

        // F6 atomic write: temp file created with explicit 0o600; fchmod
        // forces exact mode in case a hostile umask would have stripped
        // owner write (e.g. umask 0o333). Rename is atomic on the same
        // filesystem — target never exists with wider permissions.
        let temp = target + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        let fd = Darwin.open(temp, O_CREAT | O_WRONLY | O_TRUNC, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: "SocketAuthToken", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "open(\(temp)) failed: \(String(cString: strerror(errno)))"
            ])
        }
        // Force exact 0o600 regardless of umask. Paranoid defense-in-depth —
        // if the umask is unusual (e.g. 077, 333), open()'s mode arg is
        // narrowed by the umask. fchmod is NOT umask-narrowed.
        _ = Darwin.fchmod(fd, 0o600)

        let written = data.withUnsafeBytes { buf -> Int in
            Darwin.write(fd, buf.baseAddress!, data.count)
        }
        Darwin.close(fd)
        guard written == data.count else {
            Darwin.unlink(temp)
            throw NSError(domain: "SocketAuthToken", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "write truncated: \(written) of \(data.count) bytes"
            ])
        }

        guard Darwin.rename(temp, target) == 0 else {
            Darwin.unlink(temp)
            throw NSError(domain: "SocketAuthToken", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "rename(\(temp) → \(target)) failed: \(String(cString: strerror(errno)))"
            ])
        }

        return hex
    }

    /// Read the current token if one exists at `path` (default:
    /// `defaultTokenPath`) and has acceptable permissions. Returns nil when
    /// the file is absent or world/group-readable (defensive — refuse an
    /// insecure token rather than use it).
    ///
    /// **F7 note:** `Sources/HookRelay/HookRelay.swift` duplicates this
    /// logic inline (`loadAuthToken`) to preserve its zero-dep contract
    /// (Lesson #12). The two implementations must stay in sync — if you
    /// change the permission check here, mirror it there.
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

    /// F1 fix (Schneier re-audit, 2026-04-16): read the length-prefixed
    /// handshake frame from `fd` with a bounded wait, then validate.
    ///
    /// Callers previously issued a raw `read(2)` that blocked indefinitely.
    /// A same-UID attacker could open `maxConnections` sockets without
    /// sending any bytes and starve legitimate clients on the MCP listener.
    /// This helper uses `poll(2)` with `timeoutMs` before every read, so a
    /// silent client is dropped within the configured window instead of
    /// holding a task slot forever.
    ///
    /// Returns `true` iff a valid handshake was received within the
    /// timeout budget. Does NOT close `fd` — the caller owns the fd and
    /// will close on rejection.
    public static func readAndValidate(
        fd: Int32,
        expectedToken: String,
        timeoutMs: Int32 = 5000
    ) -> Bool {
        // Wait for the 4-byte length prefix.
        guard waitReadable(fd: fd, timeoutMs: timeoutMs) else { return false }

        var lengthBytes = [UInt8](repeating: 0, count: 4)
        let readLen = Darwin.read(fd, &lengthBytes, 4)
        guard readLen == 4 else { return false }

        let len = Int(UInt32(bigEndian:
            Data(lengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard len > 0, len <= maxFrameBytes else { return false }

        // Read the payload with a timeout on every continuation read, so a
        // client that sends the length prefix but stalls on the body also
        // times out instead of hanging.
        var payload = Data(count: len)
        var total = 0
        while total < len {
            guard waitReadable(fd: fd, timeoutMs: timeoutMs) else { return false }
            let n = payload.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress! + total, len - total)
            }
            if n <= 0 { return false }
            total += n
        }
        guard total == len else { return false }

        return validateHandshakePayload(payload, expectedToken: expectedToken)
    }

    /// Poll the fd for readability with a millisecond timeout. Returns true
    /// only if POLLIN fired within the window; false on timeout, error, or
    /// POLLHUP/POLLERR/POLLNVAL.
    private static func waitReadable(fd: Int32, timeoutMs: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while true {
            let rc = Darwin.poll(&pfd, 1, timeoutMs)
            if rc > 0 {
                return (pfd.revents & Int16(POLLIN)) != 0
            }
            if rc == 0 { return false } // timeout
            // rc < 0 — interrupted syscall retries; other errors fail closed.
            if errno != EINTR { return false }
        }
    }
}
