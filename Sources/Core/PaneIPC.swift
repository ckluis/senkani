import Foundation

#if canImport(Darwin)
import Darwin.POSIX
#endif

/// IPC protocol for pane control between the MCP server process (per-pane,
/// stdio) and the Senkani GUI process (SocketServerManager, listens on
/// `~/.senkani/pane.sock`).
///
/// Transport is a Unix domain socket with the same length-prefixed binary
/// protocol used by `hook.sock` and `mcp.sock`: optional `SocketAuthToken`
/// handshake frame first (when `SENKANI_SOCKET_AUTH=on`), then `UInt32
/// big-endian length + JSON payload` for every command or response.
///
/// Flow:
/// - Request-response callers (`PaneControlTool`) write a command frame,
///   poll for a response, decode.
/// - Fire-and-forget callers (`MCPSession.sendBudgetStatusIPC`) write a
///   command frame and close; no response is read. If the socket is
///   unreachable (GUI not running) the call silently no-ops.

// MARK: - Actions

public enum PaneIPCAction: String, Codable {
    case list
    case add
    case remove
    case setActive = "set_active"
    /// Fire-and-forget push from MCP → GUI. No response read by sender.
    case setBudgetStatus = "set_budget_status"
}

// MARK: - Command (MCP → GUI)

public struct PaneIPCCommand: Codable {
    public let id: String
    public let action: PaneIPCAction
    public let params: [String: String]
    public let timestamp: Date

    public init(action: PaneIPCAction, params: [String: String] = [:]) {
        self.id = UUID().uuidString
        self.action = action
        self.params = params
        self.timestamp = Date()
    }
}

// MARK: - Response (GUI → MCP)

public struct PaneIPCResponse: Codable {
    public let id: String
    public let success: Bool
    public let result: String?
    public let error: String?

    public init(id: String, success: Bool, result: String? = nil, error: String? = nil) {
        self.id = id
        self.success = success
        self.result = result
        self.error = error
    }
}

// MARK: - Socket path

public enum PaneIPCSocket {
    /// Default path of the pane control socket.
    public static var defaultPath: String {
        NSHomeDirectory() + "/.senkani/pane.sock"
    }
}

// MARK: - Fire-and-forget client

public enum PaneIPC {

    /// Outcome of a `sendFireAndForget` call.
    public enum SendOutcome: Equatable {
        /// Command framed and written to the socket in full.
        case written
        /// Socket file absent or connection refused — GUI not running.
        /// Callers treat this as a no-op, not an error.
        case socketUnreachable
        /// Socket reached but writing the frame failed (short write,
        /// remote hang-up, handshake rejected). Surfaced so tests can
        /// assert, but production callers also treat this as fire-and-forget.
        case writeFailed
        /// Encoding the command JSON failed — should never happen with
        /// the `Codable` command types.
        case encodeFailed
    }

    /// Connect to `~/.senkani/pane.sock` (or `socketPath` override for
    /// tests), write the command as one length-prefixed frame, close. Does
    /// not read a response.
    ///
    /// Never throws, never blocks on a readable socket: a 200 ms
    /// `SO_SNDTIMEO` caps the worst-case write stall (buffer-full
    /// scenarios are extremely rare for ≤ 1 KB frames but the timeout
    /// preserves fire-and-forget semantics against a misbehaving peer).
    ///
    /// Result is discardable — production callers ignore it; tests use
    /// it for assertions.
    @discardableResult
    public static func sendFireAndForget(
        _ command: PaneIPCCommand,
        socketPath: String? = nil
    ) -> SendOutcome {
        let path = socketPath ?? PaneIPCSocket.defaultPath

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let payload = try? encoder.encode(command) else {
            return .encodeFailed
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .socketUnreachable }
        defer { Darwin.close(fd) }

        // SO_SNDTIMEO — cap the write stall at 200 ms so a stuck peer
        // can't defeat fire-and-forget semantics.
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .socketUnreachable
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            pathBytes.withUnsafeBufferPointer { srcBuf in
                let count = min(srcBuf.count, rawBuf.count)
                rawBuf.baseAddress!.copyMemory(from: srcBuf.baseAddress!, byteCount: count)
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            return .socketUnreachable
        }

        // Handshake frame first when `SENKANI_SOCKET_AUTH=on` — the
        // server rejects unauthenticated clients on the gate path.
        if let token = SocketAuthToken.load(),
           let frame = SocketAuthToken.handshakeFrame(token: token) {
            let n = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, frame.count) }
            if n != frame.count {
                return .writeFailed
            }
        }

        // UInt32 big-endian length + JSON payload
        var length = UInt32(payload.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)

        let wroteLen = lengthData.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress!, 4)
        }
        guard wroteLen == 4 else { return .writeFailed }

        let wrotePayload = payload.withUnsafeBytes {
            Darwin.write(fd, $0.baseAddress!, payload.count)
        }
        guard wrotePayload == payload.count else { return .writeFailed }

        return .written
    }
}
