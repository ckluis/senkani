import Foundation
import Security

#if canImport(Darwin)
import Darwin
#endif

/// T.1d-2b-iv — inner HTTP Host/`:authority` parse + rebind to validated
/// SNI/CONNECT host + reject-on-mismatch.
///
/// ### Why
///
/// After children (ii) + (iii), the proxy terminates the client TLS and
/// re-originates a verified upstream TLS leg. The CONNECT-line + SNI
/// already pin the host the proxy DIALED. But on a reused HTTP/1.1
/// keep-alive connection, a second request can carry a DIFFERENT inner
/// `Host:` header — classic domain-fronting / connection-reuse smuggling.
/// We MUST inspect the plaintext request head, validate `Host:` matches
/// the SNI-validated CONNECT host, and FAIL-CLOSED on mismatch.
///
/// ### Scope here
///
/// This file is pure logic: bounded buffer head parse + Host header
/// extract + case-insensitive port-stripped comparison. The wiring into
/// `MITMUpstreamVerify.pipeBidirectional` lives there; this module is
/// kept side-effect-free so it can be unit-tested without a TLS socket.
///
/// ### Constraints
///
/// - Bounded buffer: 16 KiB head limit. Anything beyond rejects with
///   `.headTooLarge`. Typical request heads are 1-2 KiB; 16 KiB is the
///   same budget `EgressConnectionHandler` uses for the proxy-side
///   request head.
/// - HTTP/1.x only: if the first 4 bytes don't decode as a valid method
///   prefix, reject with `.unknownProtocol`. HTTP/2 client preface
///   (`PRI * HTTP/2.0...`) would parse as method "PRI" — defensively
///   reject anything we don't explicitly recognize as a method below.
/// - No raw mismatched host leaked: callers translate the rejection to
///   a stable `mitm_inner_host_mismatch` ruleId for the audit row. The
///   mismatched value is dropped on the floor.
/// - Case-insensitive Host comparison, port-stripped (`api.example.com`
///   == `API.Example.com` == `api.example.com:443`).
enum MITMInnerHostRebind {

    /// 16 KiB bound on the request-head bytes the rebind peek will
    /// buffer. Same shape as `EgressConnectionHandler.maxHeadBytes`.
    static let maxHeadBytes: Int = 16 * 1024

    /// Outcome of a single rebind decision.
    enum Decision: Equatable {
        /// Inner `Host:` matched the validated SNI/CONNECT host. The
        /// buffered head bytes (including the trailing `\r\n\r\n`)
        /// MUST be replayed into the upstream as the first write —
        /// they were drained from the client TLS into the rebind
        /// buffer, so the upstream pipe would otherwise see a
        /// truncated request.
        case allow(headBytes: [UInt8])
        /// Inner `Host:` did not match the validated host. Audit ruleId
        /// is the stable `mitm_inner_host_mismatch` string — the raw
        /// mismatched host is NOT surfaced (info-leak guard).
        case rejectMismatch
        /// Head exceeded `maxHeadBytes` without a `\r\n\r\n` terminator.
        /// Audit ruleId `mitm_inner_head_too_large`.
        case rejectHeadTooLarge
        /// Peek bytes don't look like an HTTP/1.x request (first token
        /// is not a recognized method). Audit ruleId
        /// `mitm_inner_unknown_protocol`. Covers HTTP/2 client preface
        /// + arbitrary binary garbage.
        case rejectUnknownProtocol
        /// SSLRead returned an error / unexpected EOF before the head
        /// was complete. Audit ruleId `mitm_inner_read_error`.
        case rejectReadError(OSStatus)
    }

    /// Whitelist of HTTP/1.x methods the rebind path will accept as a
    /// "looks like HTTP/1.x" signal. Anything else (including the
    /// HTTP/2 preface `PRI`) is rejected as unknown-protocol.
    static let knownMethods: Set<String> = [
        "GET", "HEAD", "POST", "PUT", "DELETE",
        "CONNECT", "OPTIONS", "TRACE", "PATCH"
    ]

    /// Case-insensitive, port-stripped host comparison.
    ///
    /// - `Host: api.example.com` matches validated `api.example.com`.
    /// - `Host: API.Example.COM` matches validated `api.example.com`.
    /// - `Host: api.example.com:443` matches validated `api.example.com`.
    /// - `Host: api.example.com:8443` matches validated `api.example.com`
    ///   (we strip ANY port — port-binding is enforced by the TCP
    ///   upstream connect, not the Host header).
    static func hostsMatch(innerHostHeader: String, validatedHost: String) -> Bool {
        let lhs = stripPort(innerHostHeader.trimmingCharacters(in: .whitespaces)).lowercased()
        let rhs = stripPort(validatedHost.trimmingCharacters(in: .whitespaces)).lowercased()
        return !lhs.isEmpty && lhs == rhs
    }

    /// Strip a trailing `:port` from a host string. Handles IPv6 literal
    /// hosts (`[::1]:443` → `[::1]`). For bare-host inputs (no colon, or
    /// only colons that are part of an IPv6 literal without a port
    /// suffix) returns the input unchanged.
    static func stripPort(_ host: String) -> String {
        if host.hasPrefix("[") {
            // IPv6 literal — strip `[...]:port` → `[...]`, but if no
            // port suffix exists keep the brackets.
            if let close = host.firstIndex(of: "]") {
                let bracketed = String(host[host.startIndex...close])
                // After the close-bracket, anything is the port (or nothing).
                return bracketed
            }
            return host
        }
        // IPv4 / DNS host. Last colon (if any) is the port separator.
        // A DNS host has no embedded colons; bare IPv6 without brackets
        // is malformed Host-header input — we conservatively return as-is.
        if let firstColon = host.firstIndex(of: ":"),
           host[host.index(after: firstColon)...].allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ":") }),
           host.filter({ $0 == ":" }).count == 1 {
            return String(host[..<firstColon])
        }
        return host
    }

    /// Parse a buffered HTTP/1.x request head (raw bytes up through and
    /// including `\r\n\r\n`) and return the inner Host header value if
    /// present, or nil. Header name match is case-insensitive per RFC.
    ///
    /// Returns nil if the head is malformed (no `\r\n\r\n`, no Host
    /// header, or non-UTF-8 bytes in the head). Callers treat nil as a
    /// mismatch (we never had a valid Host to compare).
    static func extractHostHeader(headBytes: [UInt8]) -> String? {
        guard let headStr = String(bytes: headBytes, encoding: .utf8) else {
            return nil
        }
        // The head must end (or be terminated) by CRLF CRLF. We split
        // on CRLF and walk header lines, skipping the first (request
        // line) and stopping at the empty line.
        let parts = headStr.components(separatedBy: "\r\n")
        guard parts.count >= 2 else { return nil }
        // parts[0] = request line; parts[1...] = headers (until empty).
        for i in 1..<parts.count {
            let line = parts[i]
            if line.isEmpty { break }  // end of headers
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIdx].lowercased().trimmingCharacters(in: .whitespaces)
            if name == "host" {
                let value = line[line.index(after: colonIdx)...]
                return String(value).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Quick "does this look like HTTP/1.x?" check on the first bytes
    /// peeked. Walks until the first space (or CRLF) and matches
    /// against `knownMethods`. Returns false for HTTP/2 client preface
    /// + arbitrary binary garbage.
    static func looksLikeHTTP1(headBytes: [UInt8]) -> Bool {
        // First token = method. We scan up to 16 bytes for the first
        // space — the longest standard method is "OPTIONS" / "CONNECT"
        // at 7 chars. If we don't see a space in 16 bytes, this isn't
        // an HTTP request line.
        var methodBytes: [UInt8] = []
        for b in headBytes.prefix(16) {
            if b == 0x20 /* SPACE */ { break }
            // CR / LF before a space → malformed.
            if b == 0x0D || b == 0x0A { return false }
            methodBytes.append(b)
        }
        guard !methodBytes.isEmpty,
              let method = String(bytes: methodBytes, encoding: .ascii) else {
            return false
        }
        return knownMethods.contains(method.uppercased())
    }

    // MARK: - SSLRead-driven head peek

    /// Read from `ssl` into a bounded buffer until either:
    ///   - the buffer contains `\r\n\r\n` → return `.allow` or
    ///     `.rejectMismatch` / `.rejectUnknownProtocol` based on
    ///     parsing,
    ///   - the buffer grows past `maxHeadBytes` → `.rejectHeadTooLarge`,
    ///   - an SSLRead error / EOF surfaces before completion →
    ///     `.rejectReadError`.
    ///
    /// Bounded would-block budget mirrors the surrounding pipe loop so
    /// a malicious / stuck client can't pin the connection thread by
    /// dribbling one byte every select-timeout.
    static func peekAndDecide(
        ssl: SSLContext,
        waitFD: Int32,
        validatedHost: String,
        maxBytes: Int = MITMInnerHostRebind.maxHeadBytes,
        wouldBlockBudget: Int = MITMUpstreamVerify.pipeWouldBlockBudget,
        selectTimeoutSeconds: Int = MITMUpstreamVerify.selectTimeoutSeconds
    ) -> Decision {
        var buf: [UInt8] = []
        buf.reserveCapacity(maxBytes)
        var chunk = [UInt8](repeating: 0, count: 4096)
        var budget = wouldBlockBudget

        while buf.count < maxBytes {
            var processed = 0
            let st = chunk.withUnsafeMutableBufferPointer { ptr -> OSStatus in
                guard let base = ptr.baseAddress else { return errSSLInternal }
                let want = min(ptr.count, maxBytes - buf.count)
                return SSLRead(ssl, base, want, &processed)
            }
            if processed > 0 {
                buf.append(contentsOf: chunk[0..<processed])
                // Reset budget on real progress.
                budget = wouldBlockBudget
                // First-bytes protocol check: as soon as we have enough
                // bytes to determine the method, reject non-HTTP/1.x
                // early without waiting for the full head.
                if buf.count >= 4 && !looksLikeHTTP1(headBytes: buf) {
                    return .rejectUnknownProtocol
                }
                if let _ = headTerminatorIndex(in: buf) {
                    return decide(headBytes: buf, validatedHost: validatedHost)
                }
                continue
            }
            if st == errSSLWouldBlock {
                budget -= 1
                if budget <= 0 {
                    return .rejectReadError(errSSLWouldBlock)
                }
                switch MITMTermination.waitReadable(fd: waitFD, seconds: selectTimeoutSeconds) {
                case .ready, .timeout: continue
                case .error: return .rejectReadError(errSSLClosedAbort)
                }
            }
            if st == errSSLClosedGraceful || st == errSSLClosedNoNotify {
                // EOF before head completion. We never got a `\r\n\r\n`,
                // so we can't validate Host. Treat as read-error.
                return .rejectReadError(st)
            }
            if st == errSecSuccess {
                // 0-byte success without progress — unusual. Treat as
                // would-block to drain the budget; don't loop forever.
                budget -= 1
                if budget <= 0 {
                    return .rejectReadError(errSSLWouldBlock)
                }
                continue
            }
            // Any other status is fail-CLOSED.
            return .rejectReadError(st)
        }
        // Drained `maxBytes` without seeing `\r\n\r\n`.
        return .rejectHeadTooLarge
    }

    /// Locate the index AFTER the `\r\n\r\n` terminator in `buf`,
    /// or nil if not present.
    static func headTerminatorIndex(in buf: [UInt8]) -> Int? {
        guard buf.count >= 4 else { return nil }
        for i in 0...(buf.count - 4) {
            if buf[i] == 0x0D && buf[i+1] == 0x0A
                && buf[i+2] == 0x0D && buf[i+3] == 0x0A {
                return i + 4
            }
        }
        return nil
    }

    /// Given a fully-buffered head + the validated host, classify the
    /// decision. Pure function — no IO.
    static func decide(headBytes: [UInt8], validatedHost: String) -> Decision {
        if !looksLikeHTTP1(headBytes: headBytes) {
            return .rejectUnknownProtocol
        }
        guard let host = extractHostHeader(headBytes: headBytes) else {
            // No Host header → treat as mismatch (HTTP/1.1 requires
            // Host; a missing-Host request to a CONNECT-validated
            // host is structurally invalid).
            return .rejectMismatch
        }
        if hostsMatch(innerHostHeader: host, validatedHost: validatedHost) {
            return .allow(headBytes: headBytes)
        }
        return .rejectMismatch
    }
}
