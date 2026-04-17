import Foundation

// MARK: - RemoteRepoClient
//
// Phase: senkani_repo (post-compound-learning round).
//
// HTTP client for the GitHub v3 REST API. Scope: anonymous + opt-in
// `GITHUB_TOKEN` auth, hard host allowlist, response-size caps,
// `SecretDetector.scan` on every response body before it escapes the
// client, rate-limit awareness.
//
// Schneier's load-bearing constraints:
//   1. Host allowlist. Every constructed URL MUST have
//      `host == "api.github.com"` or `"raw.githubusercontent.com"`.
//      Repo strings are validated through a strict regex before any
//      URL is built.
//   2. `Authorization: token …` header is attached ONLY when the
//      target host is `api.github.com` AND `GITHUB_TOKEN` is set.
//      Token never flows to `raw.githubusercontent.com` (different
//      host policy) and never lands in logs.
//   3. Every response body passes through `SecretDetector.scan`
//      before landing in a caller-visible string. A hostile fixture
//      that embeds an API key in (e.g.) a README can't turn the tool
//      into an exfiltration channel.
//   4. Response size caps. Files > 1 MB truncated with a notice.
//      Trees > 100 KB truncated. Caller sees the truncation in the
//      response text.
//
// The client is URLSession-injectable so tests can swap in a
// `URLProtocol` stub without touching the network.

public enum RemoteRepoError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidRepoIdentifier(String)
    case invalidPath(String)
    case hostNotAllowed(String)
    case rateLimited(remaining: Int?, resetAt: Date?)
    case notFound(String)
    case networkError(String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .invalidRepoIdentifier(let s):
            return "invalid repo identifier '\(s)' — expected 'owner/name' with ASCII letters, digits, or -._"
        case .invalidPath(let s):
            return "invalid path '\(s)' — must not contain .., leading /, or null bytes"
        case .hostNotAllowed(let h):
            return "host '\(h)' not in allowlist (api.github.com, raw.githubusercontent.com)"
        case .rateLimited(let rem, let reset):
            let r = rem.map(String.init) ?? "?"
            let t = reset.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
            return "rate limited — \(r) remaining, resets at \(t). Set GITHUB_TOKEN to raise the limit."
        case .notFound(let path):
            return "not found: \(path)"
        case .networkError(let msg):
            return "network: \(msg)"
        case .malformedResponse(let msg):
            return "malformed response: \(msg)"
        }
    }
}

public struct RemoteRepoResponse: Sendable {
    public let body: String
    /// Bytes fetched from the network before truncation + sanitization.
    public let rawByteCount: Int
    /// True iff response was cut below the raw size.
    public let truncated: Bool

    public init(body: String, rawByteCount: Int, truncated: Bool = false) {
        self.body = body
        self.rawByteCount = rawByteCount
        self.truncated = truncated
    }
}

public enum RemoteRepoAction: String, Sendable, CaseIterable {
    case tree
    case file
    case readme
    case search
}

public actor RemoteRepoClient {

    // MARK: - Config

    public static let apiHost     = "api.github.com"
    public static let rawHost     = "raw.githubusercontent.com"
    public static let allowedHosts: Set<String> = [apiHost, rawHost]

    public static let maxFileBytes: Int = 1_048_576        // 1 MB
    public static let maxTreeBytes: Int = 102_400          // 100 KB
    public static let maxSearchBytes: Int = 65_536         // 64 KB
    public static let defaultTimeout: TimeInterval = 15

    /// Regex: owner and name each ≤ 64 chars, letters/digits/-._,
    /// no leading/trailing separators, single slash between.
    public static let repoRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$",
            options: []
        )
    }()

    // MARK: - State

    private let session: URLSession
    private let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        // Resolve env once at construction. Empty string treated as absent.
        if let explicit = token, !explicit.isEmpty {
            self.token = explicit
        } else if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"],
                  !env.isEmpty {
            self.token = env
        } else {
            self.token = nil
        }
    }

    // MARK: - Validators

    /// Accept "owner/name" with ASCII letters, digits, `-_.`. Reject
    /// anything else — including `..`, null bytes, `@`, `//`, absolute URLs.
    public static func validateRepo(_ repo: String) throws {
        guard !repo.isEmpty, repo.count <= 160 else {
            throw RemoteRepoError.invalidRepoIdentifier(repo)
        }
        guard !repo.contains("\0"), !repo.contains("..") else {
            throw RemoteRepoError.invalidRepoIdentifier(repo)
        }
        let range = NSRange(location: 0, length: (repo as NSString).length)
        guard repoRegex.firstMatch(in: repo, options: [], range: range) != nil else {
            throw RemoteRepoError.invalidRepoIdentifier(repo)
        }
    }

    /// Path must be relative, no `..` components, no leading slash.
    public static func validatePath(_ path: String) throws {
        guard !path.contains("\0") else { throw RemoteRepoError.invalidPath(path) }
        guard !path.hasPrefix("/") else { throw RemoteRepoError.invalidPath(path) }
        for component in path.split(separator: "/") {
            if component == ".." { throw RemoteRepoError.invalidPath(path) }
        }
        guard path.count <= 2048 else { throw RemoteRepoError.invalidPath(path) }
    }

    /// Assert the URL's host is in the allowlist. Final gate before any
    /// data request is sent.
    public static func assertHostAllowed(_ url: URL) throws {
        guard let host = url.host, allowedHosts.contains(host) else {
            throw RemoteRepoError.hostNotAllowed(url.host ?? "(nil)")
        }
    }

    // MARK: - Public actions

    public func tree(repo: String, ref: String? = nil) async throws -> RemoteRepoResponse {
        try Self.validateRepo(repo)
        let branch = ref ?? "HEAD"
        // GitHub tree API via "git/trees/{ref}?recursive=1"
        let path = "/repos/\(repo)/git/trees/\(branch)?recursive=1"
        let data = try await request(
            host: Self.apiHost, path: path, cap: Self.maxTreeBytes)
        return Self.sanitize(data: data, cap: Self.maxTreeBytes)
    }

    public func file(repo: String, path: String, ref: String? = nil) async throws -> RemoteRepoResponse {
        try Self.validateRepo(repo)
        try Self.validatePath(path)
        // Use raw.githubusercontent.com — simpler, no JSON unwrap.
        let branch = ref ?? "HEAD"
        let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed) ?? path
        let urlPath = "/\(repo)/\(branch)/\(encoded)"
        let data = try await request(
            host: Self.rawHost, path: urlPath, cap: Self.maxFileBytes)
        return Self.sanitize(data: data, cap: Self.maxFileBytes)
    }

    public func readme(repo: String) async throws -> RemoteRepoResponse {
        try Self.validateRepo(repo)
        let path = "/repos/\(repo)/readme"
        let data = try await request(
            host: Self.apiHost, path: path, cap: Self.maxFileBytes)
        return Self.sanitize(data: data, cap: Self.maxFileBytes)
    }

    public func search(repo: String, query: String, limit: Int = 10) async throws -> RemoteRepoResponse {
        try Self.validateRepo(repo)
        // Strip control chars but otherwise pass through; GitHub
        // handles its own search parsing.
        let cleanedQuery = query.filter { !$0.isNewline && !$0.isWhitespace || $0 == " " }
        let encodedQ = cleanedQuery.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed) ?? cleanedQuery
        let clampedLimit = max(1, min(30, limit))
        let path = "/search/code?q=\(encodedQ)+repo:\(repo)&per_page=\(clampedLimit)"
        let data = try await request(
            host: Self.apiHost, path: path, cap: Self.maxSearchBytes)
        return Self.sanitize(data: data, cap: Self.maxSearchBytes)
    }

    // MARK: - Core request

    private func request(
        host: String,
        path: String,
        cap: Int
    ) async throws -> Data {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        // The path string includes the query — split for URLComponents.
        if let qIdx = path.firstIndex(of: "?") {
            components.path = String(path[..<qIdx])
            components.percentEncodedQuery = String(path[path.index(after: qIdx)...])
        } else {
            components.path = path
        }
        guard let url = components.url else {
            throw RemoteRepoError.malformedResponse("could not build URL for \(path)")
        }
        try Self.assertHostAllowed(url)

        var req = URLRequest(url: url, timeoutInterval: Self.defaultTimeout)
        req.httpMethod = "GET"
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("senkani-mcp/0.2", forHTTPHeaderField: "User-Agent")

        // Auth ONLY for api.github.com — Schneier constraint.
        if host == Self.apiHost, let token = self.token {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw RemoteRepoError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RemoteRepoError.malformedResponse("no HTTPURLResponse")
        }

        switch http.statusCode {
        case 200...299:
            return data
        case 403:
            // GitHub uses 403 + `X-RateLimit-Remaining: 0` for rate
            // limits. Surface the headers.
            let remaining: Int? = {
                if let s = http.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
                   let v = Int(s) { return v }
                return nil
            }()
            let reset: Date? = {
                if let s = http.value(forHTTPHeaderField: "X-RateLimit-Reset"),
                   let v = TimeInterval(s) { return Date(timeIntervalSince1970: v) }
                return nil
            }()
            if remaining == 0 {
                throw RemoteRepoError.rateLimited(remaining: remaining, resetAt: reset)
            }
            throw RemoteRepoError.networkError("HTTP 403 forbidden")
        case 404:
            throw RemoteRepoError.notFound(path)
        default:
            throw RemoteRepoError.networkError("HTTP \(http.statusCode)")
        }
    }

    // MARK: - Sanitization

    /// Apply the size cap, UTF-8 decode, and run `SecretDetector.scan`.
    /// Returns a `RemoteRepoResponse` with an explicit `truncated`
    /// flag and the pre-sanitization byte count for metrics.
    static func sanitize(data: Data, cap: Int) -> RemoteRepoResponse {
        let rawBytes = data.count
        let truncated = rawBytes > cap
        let effective = truncated ? data.prefix(cap) : data
        // UTF-8 decode with replacement for invalid bytes — an API
        // response shouldn't contain binary, but we don't want to
        // crash on pathological input.
        let raw = String(decoding: effective, as: UTF8.self)
        let scanned = SecretDetector.scan(raw).redacted
        var body = scanned
        if truncated {
            body += "\n\n// senkani_repo: response truncated at \(cap) bytes (\(rawBytes) total)"
        }
        return RemoteRepoResponse(
            body: body, rawByteCount: rawBytes, truncated: truncated)
    }
}
