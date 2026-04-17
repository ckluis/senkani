import Testing
import Foundation
@testable import Core

// MARK: - URLProtocol stub

/// Fixture-based URL protocol. Tests register `(host, path) → (status,
/// body, headers)` mappings before firing requests; the protocol
/// intercepts URLSession traffic and returns the canned response. No
/// live network hits.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {

    struct Stub: Sendable {
        let status: Int
        let body: Data
        let headers: [String: String]
    }

    nonisolated(unsafe) static var stubs: [String: Stub] = [:]
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func key(for url: URL) -> String {
        let host = url.host ?? ""
        let path = url.path
        let q = url.query.map { "?\($0)" } ?? ""
        return "\(host)\(path)\(q)"
    }

    static func register(url: URL, status: Int = 200, body: Data, headers: [String: String] = [:]) {
        stubs[key(for: url)] = Stub(status: status, body: body, headers: headers)
    }

    static func reset() {
        stubs = [:]
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let k = Self.key(for: url)
        guard let stub = Self.stubs[k] else {
            // Fall through as 404 with a helpful body so tests surface
            // an unregistered URL clearly.
            let response = HTTPURLResponse(
                url: url, statusCode: 404,
                httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("stub not registered: \(k)".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: stub.status,
            httpVersion: "HTTP/1.1", headerFields: stub.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeTestClient(token: String? = nil) -> RemoteRepoClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return RemoteRepoClient(session: session, token: token)
}

// MARK: - Validation (Schneier)

@Suite("RemoteRepoClient — repo + path validation (Schneier)")
struct RepoValidationTests {

    @Test func acceptsWellFormedRepo() throws {
        try RemoteRepoClient.validateRepo("swift/swift")
        try RemoteRepoClient.validateRepo("react-router/react-router")
        try RemoteRepoClient.validateRepo("A.B_C/x-y.z")
    }

    @Test func rejectsPathTraversal() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo("../secret/..")
        }
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo("owner/..")
        }
    }

    @Test func rejectsDoubleSlash() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo("owner//name")
        }
    }

    @Test func rejectsAtSign() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo("owner/name@evil.com")
        }
    }

    @Test func rejectsEmptyAndOversize() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo("")
        }
        let huge = String(repeating: "a", count: 200) + "/x"
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validateRepo(huge)
        }
    }

    @Test func rejectsPathWithDotDot() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validatePath("src/../etc/passwd")
        }
    }

    @Test func rejectsLeadingSlash() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validatePath("/etc/passwd")
        }
    }

    @Test func rejectsNullByte() {
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.validatePath("src/\u{0}file")
        }
    }
}

// MARK: - Host allowlist (Schneier P0)

@Suite("RemoteRepoClient — host allowlist (Schneier P0)")
struct HostAllowlistTests {

    @Test func apiHostAccepted() throws {
        let url = URL(string: "https://api.github.com/repos/x/y")!
        try RemoteRepoClient.assertHostAllowed(url)
    }

    @Test func rawHostAccepted() throws {
        let url = URL(string: "https://raw.githubusercontent.com/x/y/main/file")!
        try RemoteRepoClient.assertHostAllowed(url)
    }

    @Test func evilHostRejected() {
        let url = URL(string: "https://evil.com/repos/x/y")!
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.assertHostAllowed(url)
        }
    }

    @Test func plainGithubHostRejected() {
        // github.com (non-API) is NOT in the allowlist.
        let url = URL(string: "https://github.com/x/y")!
        #expect(throws: RemoteRepoError.self) {
            try RemoteRepoClient.assertHostAllowed(url)
        }
    }
}

// MARK: - sanitize() — SecretDetector + truncation

@Suite("RemoteRepoClient — response sanitization")
struct RepoSanitizeTests {

    @Test func redactsSecretsInBody() {
        let key = "sk-ant-api03-" + String(repeating: "X", count: 85)
        let raw = "README contains: \(key) — please ignore"
        let data = Data(raw.utf8)
        let out = RemoteRepoClient.sanitize(data: data, cap: 1_000_000)
        #expect(!out.body.contains(key))
    }

    @Test func truncatesOversizeResponse() {
        let huge = String(repeating: "x", count: 2_000_000)
        let data = Data(huge.utf8)
        let out = RemoteRepoClient.sanitize(data: data, cap: 1_048_576)
        #expect(out.truncated)
        #expect(out.body.contains("truncated"))
        #expect(out.body.utf8.count < 2_000_000)
    }

    @Test func smallResponseNotTruncated() {
        let data = Data("hello".utf8)
        let out = RemoteRepoClient.sanitize(data: data, cap: 1_000)
        #expect(!out.truncated)
        #expect(out.body == "hello")
        #expect(out.rawByteCount == 5)
    }
}

// MARK: - Live request paths (via URLProtocol stub)
//
// The URLProtocol stub's `stubs` dictionary is process-global, so all
// tests that use it serialize into ONE suite — cross-suite
// parallelism would race on stub registrations.

@Suite("RemoteRepoClient — network paths (URLProtocol stub)", .serialized)
struct RepoNetworkPathTests {

    @Test func treeAction() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/git/trees/HEAD?recursive=1")!
        let body = #"{"tree":[{"path":"a.swift"},{"path":"b.swift"}]}"#
        MockURLProtocol.register(url: url, body: Data(body.utf8))

        let client = makeTestClient()
        let response = try await client.tree(repo: "owner/name")
        #expect(response.body.contains("a.swift"))
        #expect(response.body.contains("b.swift"))
    }

    @Test func fileAction() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://raw.githubusercontent.com/owner/name/HEAD/src/main.swift")!
        MockURLProtocol.register(url: url, body: Data("print(\"hi\")".utf8))

        let client = makeTestClient()
        let response = try await client.file(repo: "owner/name", path: "src/main.swift")
        #expect(response.body.contains("print"))
    }

    @Test func readmeAction() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/readme")!
        MockURLProtocol.register(url: url, body: Data(#"{"name":"README.md","content":"base64"}"#.utf8))

        let client = makeTestClient()
        let response = try await client.readme(repo: "owner/name")
        #expect(response.body.contains("README.md"))
    }

    @Test func searchAction() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/search/code?q=authenticate+repo:owner/name&per_page=10")!
        MockURLProtocol.register(url: url, body: Data(#"{"items":[{"path":"auth.swift"}]}"#.utf8))

        let client = makeTestClient()
        let response = try await client.search(
            repo: "owner/name", query: "authenticate")
        #expect(response.body.contains("auth.swift"))
    }

    // MARK: Error paths

    @Test func notFoundPropagates() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let client = makeTestClient()
        do {
            _ = try await client.tree(repo: "owner/missing")
            Issue.record("expected .notFound")
        } catch let e as RemoteRepoError {
            if case .notFound = e { return }
            Issue.record("expected .notFound, got \(e)")
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func rateLimitPropagates() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/git/trees/HEAD?recursive=1")!
        MockURLProtocol.register(
            url: url, status: 403,
            body: Data(#"{"message":"API rate limit exceeded"}"#.utf8),
            headers: [
                "X-RateLimit-Remaining": "0",
                "X-RateLimit-Reset": "1713360000",
            ]
        )
        let client = makeTestClient()
        do {
            _ = try await client.tree(repo: "owner/name")
            Issue.record("expected .rateLimited")
        } catch let e as RemoteRepoError {
            switch e {
            case .rateLimited(let remaining, _):
                #expect(remaining == 0)
            default:
                Issue.record("expected .rateLimited, got \(e)")
            }
        } catch {
            Issue.record("unexpected: \(error)")
        }
    }

    @Test func invalidRepoRejectedBeforeNetwork() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let client = makeTestClient()
        do {
            _ = try await client.tree(repo: "../etc/passwd")
            Issue.record("expected .invalidRepoIdentifier")
        } catch let e as RemoteRepoError {
            if case .invalidRepoIdentifier = e { return }
            Issue.record("expected .invalidRepoIdentifier, got \(e)")
        } catch {
            Issue.record("unexpected: \(error)")
        }
        // Nothing should have hit the network.
        #expect(MockURLProtocol.lastRequest == nil)
    }

    // MARK: Auth header gating (Schneier)

    @Test func authHeaderPresentOnApiHostWhenTokenSet() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/readme")!
        MockURLProtocol.register(url: url, body: Data(#"{"ok":true}"#.utf8))

        let client = makeTestClient(token: "ghp_testtoken123")
        _ = try await client.readme(repo: "owner/name")
        let auth = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == "Bearer ghp_testtoken123")
    }

    @Test func authHeaderAbsentOnRawHostEvenWithToken() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://raw.githubusercontent.com/owner/name/HEAD/file.md")!
        MockURLProtocol.register(url: url, body: Data("hello".utf8))

        let client = makeTestClient(token: "ghp_testtoken123")
        _ = try await client.file(repo: "owner/name", path: "file.md")
        let auth = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == nil,
            "token must NOT flow to raw.githubusercontent.com — different host policy")
    }

    @Test func authHeaderAbsentWhenNoTokenSet() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/readme")!
        MockURLProtocol.register(url: url, body: Data(#"{"ok":true}"#.utf8))

        let client = makeTestClient(token: nil)
        _ = try await client.readme(repo: "owner/name")
        let auth = MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization")
        #expect(auth == nil, "anonymous access must send no Authorization")
    }
}

// MARK: - Cache (separate suite — no URLProtocol dependency)

@Suite("RemoteRepoCache", .serialized)
struct RemoteRepoCacheTests {

    @Test func getReturnsStoredBody() async {
        let cache = RemoteRepoCache(ttl: 60)
        await cache.put("k", body: "v")
        let got = await cache.get("k")
        #expect(got == "v")
    }

    @Test func ttlExpiresEntries() async {
        let cache = RemoteRepoCache(ttl: 1)
        await cache.put("k", body: "v", now: Date(timeIntervalSince1970: 0))
        let got = await cache.get("k", now: Date(timeIntervalSince1970: 60))
        #expect(got == nil, "entry past TTL must be treated as absent")
    }

    @Test func lruEvictsOldest() async {
        let cache = RemoteRepoCache(ttl: 3600, maxEntries: 2)
        await cache.put("a", body: "1")
        await cache.put("b", body: "2")
        await cache.put("c", body: "3")  // evicts "a"
        #expect(await cache.get("a") == nil)
        #expect(await cache.get("b") == "2")
        #expect(await cache.get("c") == "3")
    }

    @Test func clearEmpties() async {
        let cache = RemoteRepoCache()
        await cache.put("k", body: "v")
        await cache.clear()
        #expect(await cache.count() == 0)
    }
}
