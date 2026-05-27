import Foundation
import CryptoKit

/// V.13a-2 — bearer-auth admission gate for the OpenAI-compatible
/// endpoint. Pure and side-effect-free (the only mutable state is the
/// injected `OpenAIRateLimiter`), so every acceptance bullet is testable
/// without binding a socket.
///
/// Decision order (security-first):
///   1. No / malformed `Authorization: Bearer …`  → `401`.
///   2. Well-formed bearer that matches no vault key → `401`.
///   3. Matched key past its `expiresAt`           → `401`.
///   4. Matched, live key whose `scope` excludes the
///      requested surface                          → `403`.
///   5. Matched, live, in-scope key over its
///      per-key rate limit                         → `429` + `Retry-After`.
///   6. Otherwise                                  → `ok`.
///
/// Schneier P0 contract:
///   - Key match is a CONSTANT-TIME compare over the fixed-length
///     SHA-256 hashes, looping every record with no early return, so
///     "no such key" and "wrong key" are indistinguishable by timing
///     (both traverse the full record set and return the same `401`
///     reason `"invalid key"`).
///   - The compare folds any length delta into the running diff instead
///     of short-circuiting on a length mismatch, so even a malformed
///     hash cannot leak via an early return.
public enum OpenAIAuthGate {

    public enum Decision: Sendable, Equatable {
        case ok(label: String?)
        case unauthorized(reason: String)        // 401
        case forbidden(reason: String)           // 403
        case rateLimited(retryAfterSeconds: Int) // 429
    }

    // MARK: - Token extraction

    /// Extract the bearer token from an `Authorization` header value.
    /// Case-insensitive on the `Bearer` keyword. Returns nil for a
    /// missing, empty, or malformed header (no scheme, wrong scheme, or
    /// empty token).
    public static func bearerToken(fromHeader header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        let token = parts[1].trimmingCharacters(in: .whitespaces)
        return token.isEmpty ? nil : token
    }

    // MARK: - Hashing + constant-time compare

    /// Hex SHA-256 of a key string. The vault stores this; the gate
    /// recomputes it on the presented key and compares.
    public static func hash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time equality with NO early return on length mismatch.
    /// A length delta is folded into the running diff so neither a
    /// length nor a content mismatch is distinguishable by compare
    /// latency. (For SHA-256 hashes both operands are always 64 hex
    /// chars, so the length branch never actually fires in production —
    /// the no-short-circuit shape is belt-and-suspenders against a
    /// malformed stored hash.)
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        var diff: UInt8 = UInt8(truncatingIfNeeded: ab.count ^ bb.count)
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x: UInt8 = i < ab.count ? ab[i] : 0
            let y: UInt8 = i < bb.count ? bb[i] : 0
            diff |= x ^ y
            i += 1
        }
        return diff == 0
    }

    /// Find the vault record matching `presentedKey`, traversing EVERY
    /// record with no early return. Returns the matched record or nil.
    /// The full-traversal shape is the timing-oracle defense: lookup
    /// cost is proportional to the record count, not to which record
    /// (if any) matched.
    public static func matchRecord(
        presentedKey: String,
        records: [OpenAIKeyRecord]
    ) -> OpenAIKeyRecord? {
        let presentedHash = hash(presentedKey)
        var matched: OpenAIKeyRecord?
        for record in records {
            if constantTimeEquals(presentedHash, record.keyHash) {
                matched = record   // deliberately no `break`
            }
        }
        return matched
    }

    // MARK: - Surface routing

    /// Map a request path to the scope-surface it requires, or nil when
    /// the path needs no specific surface scope (e.g. `/v1/models`).
    /// Tool-use rides the chat path; the `tools` scope is enforced in
    /// v13d, so v13a-2 derives only `chat` / `embeddings` from the path.
    public static func surface(forPath path: String) -> String? {
        if path.hasPrefix("/v1/chat") { return "chat" }
        if path.hasPrefix("/v1/embeddings") { return "embeddings" }
        return nil
    }

    // MARK: - Decision

    public static func decide(
        authorizationHeader: String?,
        requestedSurface: String?,
        now: Date,
        records: [OpenAIKeyRecord],
        rateLimiter: OpenAIRateLimiter
    ) -> Decision {
        guard let token = bearerToken(fromHeader: authorizationHeader) else {
            return .unauthorized(reason: "missing or malformed Authorization header")
        }
        guard let record = matchRecord(presentedKey: token, records: records) else {
            // Same reason for "no such key" and "wrong key" — no oracle.
            return .unauthorized(reason: "invalid key")
        }
        if let expiresAt = record.expiresAt, now >= expiresAt {
            return .unauthorized(reason: "key expired")
        }
        if let surface = requestedSurface, !record.scope.contains(surface) {
            return .forbidden(reason: "key scope does not include surface '\(surface)'")
        }
        let admit = rateLimiter.admit(keyHash: record.keyHash, limit: record.rateLimit, now: now)
        if !admit.allowed {
            return .rateLimited(retryAfterSeconds: admit.retryAfter)
        }
        return .ok(label: record.label)
    }

    // MARK: - HTTP response rendering

    /// Render the HTTP error response for a non-`ok` decision, or nil
    /// for `ok` (the caller falls through to the real surface / 501).
    public static func errorResponse(for decision: Decision) -> Data? {
        switch decision {
        case .ok:
            return nil
        case .unauthorized(let reason):
            return OpenAIHTTPResponse.render(
                code: 401, message: "Unauthorized",
                body: errorBody(message: reason, type: "invalid_request_error", code: "invalid_api_key")
            )
        case .forbidden(let reason):
            return OpenAIHTTPResponse.render(
                code: 403, message: "Forbidden",
                body: errorBody(message: reason, type: "invalid_request_error", code: "insufficient_scope")
            )
        case .rateLimited(let retryAfter):
            return OpenAIHTTPResponse.render(
                code: 429, message: "Too Many Requests",
                body: errorBody(message: "rate limit exceeded", type: "rate_limit_error", code: "rate_limit_exceeded"),
                extraHeaders: ["Retry-After": "\(retryAfter)"]
            )
        }
    }

    /// OpenAI-shaped error JSON body.
    static func errorBody(message: String, type: String, code: String?) -> String {
        let escaped = message
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        if let code {
            return "{\"error\":{\"message\":\"\(escaped)\",\"type\":\"\(type)\",\"code\":\"\(code)\"}}"
        }
        return "{\"error\":{\"message\":\"\(escaped)\",\"type\":\"\(type)\"}}"
    }
}

/// Pure HTTP/1.1 response builder shared by `OpenAIAuthGate` and
/// `OpenAIListener`. Not gated on `Network` so the auth path is fully
/// unit-testable on any platform.
public enum OpenAIHTTPResponse {
    public static func render(
        code: Int,
        message: String,
        body: String,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        let bodyData = Data(body.utf8)
        var head = "HTTP/1.1 \(code) \(message)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        // Deterministic header order for testability.
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            head += "\(k): \(v)\r\n"
        }
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(bodyData)
        return out
    }
}

/// V.13a-2 — per-key fixed-window rate limiter. One 60-second window
/// per key hash; the window resets lazily on the first request after it
/// elapses. Thread-safe via an `NSLock` so the `NWConnection` accept
/// callbacks (which fire on the listener's dispatch queue) can share one
/// limiter without data races.
public final class OpenAIRateLimiter: @unchecked Sendable {
    /// Fixed window length in seconds.
    public static let windowSeconds: Double = 60

    private let lock = NSLock()
    private var windows: [String: (start: Date, count: Int)] = [:]

    public init() {}

    /// Admit (or reject) one request for `keyHash` under `limit`
    /// requests-per-window. Returns `(allowed, retryAfter)` — `retryAfter`
    /// is seconds until the current window resets (≥ 1) when rejected,
    /// `0` when allowed.
    public func admit(keyHash: String, limit: Int, now: Date = Date()) -> (allowed: Bool, retryAfter: Int) {
        let effectiveLimit = limit > 0 ? limit : OpenAIKeyRecord.defaultRateLimit
        lock.lock(); defer { lock.unlock() }

        if let window = windows[keyHash],
           now.timeIntervalSince(window.start) < OpenAIRateLimiter.windowSeconds {
            if window.count >= effectiveLimit {
                let remaining = OpenAIRateLimiter.windowSeconds - now.timeIntervalSince(window.start)
                return (false, max(1, Int(remaining.rounded(.up))))
            }
            windows[keyHash] = (window.start, window.count + 1)
            return (true, 0)
        }
        // No window, or the prior window elapsed → start a fresh one.
        windows[keyHash] = (now, 1)
        return (true, 0)
    }
}
