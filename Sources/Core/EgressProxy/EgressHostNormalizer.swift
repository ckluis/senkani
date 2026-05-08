import Foundation

/// Normalizes a host (or host:port) string to a canonical form for rule
/// matching.
///
/// The normalizer is the load-bearing comparator inside the static rule
/// engine: a rule like `example.com` MUST match `Example.COM:80`,
/// `example.com.`, and `EXAMPLE.com:80/` (the trailing slash variant
/// shows up in CONNECT lines under some clients). Inconsistent
/// normalization is the classic egress-allowlist bypass — Karpathy
/// audit 2026-05-06.
///
/// Steps applied (in order):
///   1. Strip ASCII whitespace.
///   2. Strip a trailing slash if present (CONNECT lines may include `/`).
///   3. Strip the default port if present (`:80` for HTTP, `:443` for HTTPS).
///   4. Strip a single trailing dot (FQDN root).
///   5. ASCII-lowercase.
///
/// Non-ASCII / IDNA hosts are passed through case-folded but otherwise
/// untouched. Punycode is the operator's responsibility to feed in
/// already-encoded; we don't decode UTS-46 here.
public enum EgressHostNormalizer {

    /// Default ports that get stripped during normalization. Plain HTTP
    /// is 80; plain HTTPS is 443. Anything else stays explicit so a
    /// rule for `example.com:8443` doesn't accidentally match a request
    /// for `example.com` (port 443).
    public static let defaultStrippablePorts: Set<Int> = [80, 443]

    public static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasSuffix("/") {
            s.removeLast()
        }
        // Strip trailing dot BEFORE port stripping — combined inputs like
        // `example.com:80.` would otherwise produce `80.` for the port
        // part and fail Int conversion. Operator-supplied hosts in the
        // wild combine these in arbitrary order.
        if s.hasSuffix(".") {
            s.removeLast()
        }
        // Strip default port if exactly `:80` or `:443` at the end.
        if let colonIdx = s.lastIndex(of: ":"),
           s.distance(from: colonIdx, to: s.endIndex) <= 5 {
            let portPart = s[s.index(after: colonIdx)...]
            if let port = Int(portPart),
               defaultStrippablePorts.contains(port) {
                s = String(s[..<colonIdx])
            }
        }
        return s.lowercased()
    }

    /// Split `host[:port]` into its parts. Used by the CONNECT-line parser
    /// — CONNECT always carries a port. Returns nil if the input is
    /// malformed (no port, or non-integer port).
    public static func splitHostPort(_ raw: String) -> (host: String, port: Int)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colonIdx = s.lastIndex(of: ":") else { return nil }
        let hostPart = String(s[..<colonIdx])
        let portPart = String(s[s.index(after: colonIdx)...])
        guard let port = Int(portPart), port > 0, port < 65536 else { return nil }
        guard !hostPart.isEmpty else { return nil }
        return (hostPart, port)
    }
}
