import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Injection seam for the upstream-connect step of the egress
/// daemon's allow arm. Adopters return a connected fd (caller owns,
/// must `close()`) or nil on connect failure.
///
/// Production: `DefaultEgressUpstreamConnector` — pure POSIX
/// `getaddrinfo` + `connect(2)` (delegates to
/// `EgressUpstreamConnector.connect`).
///
/// Tests: a loopback stub that ignores `host` and dials a
/// pre-bound fixture port — lets the live ALLOW-arm test exercise
/// `EgressListener` → `EgressConnectionHandler` without dialing the
/// real upstream from CI. Introduced V.13b-4d-ii.
public protocol EgressUpstreamConnecting: Sendable {
    func connect(host: String, port: Int) -> Int32?
}

/// Default production adopter: forwards directly to the static
/// `EgressUpstreamConnector.connect(host:port:)` path so behavior is
/// byte-equivalent to the pre-seam call. Parity test pins this.
public struct DefaultEgressUpstreamConnector: EgressUpstreamConnecting {
    public init() {}
    public func connect(host: String, port: Int) -> Int32? {
        EgressUpstreamConnector.connect(host: host, port: port)
    }
}

/// Resolve `host:port` and open a TCP connection to the first usable
/// address. Pure POSIX `getaddrinfo` + `connect` — no Foundation
/// `URLSession` to keep the code path testable and free of background
/// queues.
///
/// Returns a connected fd or nil on resolution / connect failure.
/// Caller owns the fd and is responsible for `close()`.
public enum EgressUpstreamConnector {
    public static func connect(host: String, port: Int, timeoutSeconds: Int = 5) -> Int32? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { return nil }
        defer { freeaddrinfo(res) }

        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if fd >= 0 {
                applyConnectTimeout(fd: fd, seconds: timeoutSeconds)
                let cr = Darwin.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if cr == 0 {
                    return fd
                }
                close(fd)
            }
            cursor = info.pointee.ai_next
        }
        return nil
    }

    private static func applyConnectTimeout(fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}
