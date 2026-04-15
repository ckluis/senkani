import Foundation

/// Result of a daemon socket health check.
public enum DaemonHealthResult: Equatable, Sendable {
    case pass       // Socket responsive
    case fail       // No socket or connection refused
    case warn       // Socket exists but timed out
}

/// Checks if a Unix domain socket is responsive.
/// Used by `senkani doctor` to verify the daemon is running.
public enum DaemonHealthCheck {

    /// Check if a socket at the given path is responsive.
    /// Attempts to connect with a timeout. Returns .pass if connected,
    /// .fail if socket doesn't exist or connection refused, .warn if timeout.
    public static func check(socketPath: String, timeoutMs: Int32 = 1000) -> DaemonHealthResult {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            return .fail
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .fail }
        defer { Darwin.close(fd) }

        // Set non-blocking for timeout-aware connect
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Build sockaddr_un
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            return .fail
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { buf in
                let dest = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                buf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buf.count) { src in
                    dest.update(from: src, count: buf.count)
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        if connectResult == 0 {
            return .pass  // Connected immediately
        }

        guard errno == EINPROGRESS else {
            return .fail  // Connection refused or other error
        }

        // Wait with poll for the connection to complete
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFD, 1, timeoutMs)

        if pollResult > 0 && (pollFD.revents & Int16(POLLOUT) != 0) {
            var error: Int32 = 0
            var errorLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &errorLen)
            return error == 0 ? .pass : .fail
        } else if pollResult == 0 {
            return .warn  // Timeout
        } else {
            return .fail  // Poll error
        }
    }
}
