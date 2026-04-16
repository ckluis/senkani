import Foundation
import MCP
import Core

/// MCP tool for controlling workspace panes via Unix socket IPC.
/// Connects to ~/.senkani/pane.sock using the same length-prefixed protocol as hooks.
/// Instant response (<10ms) vs the old 5-second file polling.
enum PaneControlTool {
    private static let socketPath = NSHomeDirectory() + "/.senkani/pane.sock"

    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let actionStr = arguments?["action"]?.stringValue,
              let action = PaneIPCAction(rawValue: actionStr) else {
            return .init(
                content: [.text(text: "Error: 'action' is required (list, add, remove, set_active)", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Build params from arguments
        var params: [String: String] = [:]
        for key in ["type", "title", "command", "url", "pane_id"] {
            if let val = arguments?[key]?.stringValue {
                params[key] = val
            }
        }

        let command = PaneIPCCommand(action: action, params: params)

        // Encode command
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(command) else {
            return .init(
                content: [.text(text: "Error: failed to encode command", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Connect to pane socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .init(
                content: [.text(text: "Error: failed to create socket", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
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
            return .init(
                content: [.text(text: "Error: Senkani app not running (connection refused on pane.sock). Start the app first.", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // P2-12: send handshake frame first when a token file exists. Server
        // rejects unauthenticated clients when SENKANI_SOCKET_AUTH=on.
        if let token = SocketAuthToken.load(), let frame = SocketAuthToken.handshakeFrame(token: token) {
            _ = frame.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, frame.count) }
        }

        // Send: 4-byte length + JSON
        var length = UInt32(data.count).bigEndian
        let lengthData = Data(bytes: &length, count: 4)
        _ = lengthData.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, 4) }
        _ = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }

        // Read response with 5s timeout
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let pollResult = poll(&pollFD, 1, 5000)
        guard pollResult > 0 else {
            return .init(
                content: [.text(text: "Error: timeout waiting for pane response", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Read 4-byte length prefix
        var respLengthBytes = [UInt8](repeating: 0, count: 4)
        guard Darwin.read(fd, &respLengthBytes, 4) == 4 else {
            return .init(
                content: [.text(text: "Error: failed to read response length", annotations: nil, _meta: nil)],
                isError: true
            )
        }
        let respLength = Int(UInt32(bigEndian: Data(respLengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard respLength > 0, respLength < 65536 else {
            return .init(
                content: [.text(text: "Error: invalid response length", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Read response payload
        var respBuffer = Data(count: respLength)
        var totalRead = 0
        while totalRead < respLength {
            let n = respBuffer.withUnsafeMutableBytes { buf in
                Darwin.read(fd, buf.baseAddress! + totalRead, respLength - totalRead)
            }
            if n <= 0 { break }
            totalRead += n
        }
        guard totalRead == respLength else {
            return .init(
                content: [.text(text: "Error: incomplete response", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // Decode response
        let decoder = JSONDecoder()
        guard let response = try? decoder.decode(PaneIPCResponse.self, from: respBuffer) else {
            return .init(
                content: [.text(text: "Error: malformed response from app", annotations: nil, _meta: nil)],
                isError: true
            )
        }

        if response.success {
            return .init(
                content: [.text(text: response.result ?? "OK", annotations: nil, _meta: nil)],
                isError: false
            )
        } else {
            return .init(
                content: [.text(text: "Error: \(response.error ?? "unknown error")", annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }
}
