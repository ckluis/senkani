import Foundation

/// Parsed HTTP request line. The egress proxy reads exactly the first
/// line off a connection to make its decision; full header parsing only
/// happens for plain-HTTP request bodies that the proxy will rewrite
/// on the way upstream (T.1a.2 follow-up).
///
/// Two forms the proxy must recognize:
///   1. Absolute-URL form (HTTP_PROXY): `GET http://host/path HTTP/1.1`
///      — the host comes from the URL, not the `Host:` header.
///   2. CONNECT form (HTTPS_PROXY): `CONNECT host:port HTTP/1.1` — the
///      host:port is the second token; CONNECT has no path.
public enum HTTPRequestLine {

    public struct ParsedRequest: Sendable, Equatable {
        public let method: String
        public let host: String
        public let port: Int
        public let path: String?
        public let httpVersion: String

        public init(method: String, host: String, port: Int, path: String?, httpVersion: String) {
            self.method = method
            self.host = host
            self.port = port
            self.path = path
            self.httpVersion = httpVersion
        }
    }

    public enum ParseError: Error, Equatable {
        case empty
        case malformed
        case unsupportedMethod(String)
        case missingHost
    }

    /// Parse exactly the first line. Caller has stripped CR/LF already.
    /// Returns the request meta or a typed error so the proxy can log
    /// what it rejected.
    public static func parse(_ line: String) throws -> ParsedRequest {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw ParseError.empty }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3 else { throw ParseError.malformed }
        let method = parts[0].uppercased()
        let target = parts[1]
        let version = parts[2]

        if method == "CONNECT" {
            guard let split = EgressHostNormalizer.splitHostPort(target) else {
                throw ParseError.missingHost
            }
            return ParsedRequest(
                method: method,
                host: split.host,
                port: split.port,
                path: nil,
                httpVersion: version
            )
        }

        // Plain HTTP via HTTP_PROXY: target is an absolute URL.
        // Do NOT fall back to relative form — origin-form requests
        // belong to the upstream after rewrite, not to the proxy.
        guard target.hasPrefix("http://") || target.hasPrefix("https://") else {
            throw ParseError.missingHost
        }
        guard let url = URL(string: target),
              let host = url.host, !host.isEmpty else {
            throw ParseError.missingHost
        }
        let port = url.port ?? (target.hasPrefix("https://") ? 443 : 80)
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")

        // Methods other than the standard set are still valid HTTP — we
        // route by method for telemetry only, not for filtering. The
        // rule engine evaluates host, not method.
        return ParsedRequest(
            method: method,
            host: host,
            port: port,
            path: path,
            httpVersion: version
        )
    }
}
