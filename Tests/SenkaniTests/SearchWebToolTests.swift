import Testing
import Foundation
@testable import MCPServer
@testable import Core

// MARK: - guard-research query filter

@Suite("SearchWeb — guard-research query filter")
struct SearchWebQueryGuardTests {

    @Test("Public topic query is allowed")
    func cleanQueryAllowed() {
        #expect(SearchWebQueryGuard.evaluate("DuckDuckGo Lite parser") == .allow)
    }

    @Test("Empty / whitespace query is blocked")
    func emptyQueryBlocked() {
        #expect(SearchWebQueryGuard.evaluate("   ") != .allow)
    }

    @Test("Absolute Unix workstation path is blocked")
    func absoluteUnixPathBlocked() {
        switch SearchWebQueryGuard.evaluate("how to use /Users/clank/secret_notes") {
        case .block: break
        case .allow: Issue.record("expected block for /Users/ path")
        }
        switch SearchWebQueryGuard.evaluate("look up /etc/passwd contents") {
        case .block: break
        case .allow: Issue.record("expected block for /etc/ path")
        }
    }

    @Test("Tilde-home path is blocked")
    func tildeHomePathBlocked() {
        switch SearchWebQueryGuard.evaluate("scan ~/Library/Keychains for keys") {
        case .block: break
        case .allow: Issue.record("expected block for ~/ path")
        }
    }

    @Test("Glob pattern is blocked")
    func globPatternBlocked() {
        switch SearchWebQueryGuard.evaluate("match /tmp/*.swift files") {
        case .block: break
        case .allow: Issue.record("expected block for /tmp/*.swift")
        }
        switch SearchWebQueryGuard.evaluate("**/*.json findings") {
        case .block: break
        case .allow: Issue.record("expected block for **/*")
        }
    }

    @Test("Secret-shaped tokens (Anthropic, AWS, GitHub, OpenAI) are blocked")
    func secretShapedTokenBlocked() {
        // Use clearly fake-but-pattern-matching tokens.
        let secrets = [
            "what is sk-ant-xxxxxxxxxxxxxxxxxxxxxxxxxx good for",
            "AKIAABCDEFGHIJKLMNOP usage",
            "ghp_abcdefghijklmnopqrstuvwxyzABCDEFGHIJ exploitation",
        ]
        for q in secrets {
            switch SearchWebQueryGuard.evaluate(q) {
            case .block: continue
            case .allow: Issue.record("expected block for query containing secret-shaped token: \(q)")
            }
        }
    }

    @Test("Quoted operators and site: searches still pass")
    func operatorsPass() {
        #expect(SearchWebQueryGuard.evaluate("site:example.com markdown rendering") == .allow)
        #expect(SearchWebQueryGuard.evaluate("\"exact phrase\" OR alternative") == .allow)
    }
}

// MARK: - DDG Lite URL builder

@Suite("SearchWeb — DuckDuckGo Lite URL builder")
struct DuckDuckGoLiteURLBuilderTests {

    @Test("Builds URL with query, region, and recency")
    func buildsFullURL() throws {
        let result = DuckDuckGoLiteURLBuilder.build(
            query: "tree-sitter incremental parsing",
            region: "wt-wt",
            recency: "w"
        )
        let url = try unwrapURL(result)
        #expect(url.host == "lite.duckduckgo.com")
        // URL.path strips trailing slash; check the absoluteString preserves /lite/.
        #expect(url.absoluteString.contains("/lite/"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["q"] == "tree-sitter incremental parsing")
        #expect(items["kl"] == "wt-wt")
        #expect(items["df"] == "w")
    }

    @Test("recency=any omits the df parameter")
    func recencyAnyOmitsDf() throws {
        let url = try unwrapURL(DuckDuckGoLiteURLBuilder.build(
            query: "x", region: "us-en", recency: "any"))
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let names = (comps.queryItems ?? []).map(\.name)
        #expect(!names.contains("df"))
    }

    @Test("Invalid recency returns invalidRecency error")
    func invalidRecencyRejected() {
        let result = DuckDuckGoLiteURLBuilder.build(
            query: "x", region: "wt-wt", recency: "ever")
        switch result {
        case .success: Issue.record("expected invalidRecency failure")
        case .failure(let e):
            #expect(e == .invalidRecency("ever"))
        }
    }

    @Test("Allowed host constant pins to lite.duckduckgo.com")
    func hostPinned() {
        #expect(DuckDuckGoLiteURLBuilder.allowedHost == "lite.duckduckgo.com")
    }

    private func unwrapURL(_ r: Result<URL, SearchWebError>) throws -> URL {
        switch r {
        case .success(let u): return u
        case .failure(let e):
            Issue.record("URL builder failed: \(e)")
            throw e
        }
    }
}

// MARK: - DDG Lite HTML parser

@Suite("SearchWeb — DuckDuckGo Lite HTML parser")
struct DuckDuckGoLiteParserTests {

    /// Minimal Lite-shaped HTML with three results.
    static let sampleHTML = """
    <html><body><table>
    <tr>
      <td class="link" valign="top">1.</td>
      <td class="result-link"><a rel="nofollow" class="result-link" href="https://example.com/a">First &amp; Best Result</a></td>
    </tr>
    <tr><td></td><td class="result-snippet">Concise snippet about the first result with &lt;tag&gt;.</td></tr>
    <tr><td></td><td><span class="link-text">example.com</span></td></tr>

    <tr>
      <td class="link" valign="top">2.</td>
      <td class="result-link"><a rel="nofollow" class="result-link" href="https://example.org/b">Second Match</a></td>
    </tr>
    <tr><td></td><td class="result-snippet">Snippet two.</td></tr>

    <tr>
      <td class="link" valign="top">3.</td>
      <td class="result-link"><a rel="nofollow" class="result-link" href="https://example.net/c">Third Hit</a></td>
    </tr>
    <tr><td></td><td class="result-snippet">Snippet three.</td></tr>
    </table></body></html>
    """

    @Test("Parses three Lite-shaped results with title/url/snippet")
    func parsesThreeResults() throws {
        let r = try DuckDuckGoLiteParserTests.unwrap(
            DuckDuckGoLiteParser.parse(html: Self.sampleHTML, limit: 10))
        #expect(r.count == 3)
        #expect(r[0].title == "First & Best Result")
        #expect(r[0].url == "https://example.com/a")
        #expect(r[0].snippet.contains("Concise snippet"))
        #expect(r[0].snippet.contains("<tag>"))   // entity decoded
        #expect(r[2].url == "https://example.net/c")
    }

    @Test("Empty body returns BackendBlocked (cannot silently return zero)")
    func emptyBodyBlocked() {
        switch DuckDuckGoLiteParser.parse(html: "   ", limit: 10) {
        case .success: Issue.record("expected backendBlocked for empty body")
        case .failure(let e): #expect(e == .backendBlocked)
        }
    }

    @Test("CAPTCHA-shaped page (anomaly, no result-link) returns BackendBlocked")
    func captchaShapeBlocked() {
        let html = "<html><body>Anomaly detected. Please solve the captcha.</body></html>"
        switch DuckDuckGoLiteParser.parse(html: html, limit: 10) {
        case .success: Issue.record("expected backendBlocked for CAPTCHA page")
        case .failure(let e): #expect(e == .backendBlocked)
        }
    }

    @Test("Page without any result-link is treated as backend block")
    func noResultsBlocked() {
        let html = "<html><body><div>An article about something else</div></body></html>"
        switch DuckDuckGoLiteParser.parse(html: html, limit: 10) {
        case .success: Issue.record("expected backendBlocked when no result-link present")
        case .failure(let e): #expect(e == .backendBlocked)
        }
    }

    @Test("limit caps the result count")
    func limitCapsResults() throws {
        let r = try DuckDuckGoLiteParserTests.unwrap(
            DuckDuckGoLiteParser.parse(html: Self.sampleHTML, limit: 2))
        #expect(r.count == 2)
    }

    @Test("HTML entity decoder handles named + numeric entities")
    func htmlDecode() {
        #expect(DuckDuckGoLiteParser.htmlDecode("foo &amp; bar") == "foo & bar")
        #expect(DuckDuckGoLiteParser.htmlDecode("&lt;b&gt;x&lt;/b&gt;") == "<b>x</b>")
        #expect(DuckDuckGoLiteParser.htmlDecode("ten&#37;") == "ten%")
    }

    static func unwrap<T>(_ r: Result<T, SearchWebError>) throws -> T {
        switch r {
        case .success(let v): return v
        case .failure(let e):
            Issue.record("parser failed: \(e)")
            throw e
        }
    }
}

// MARK: - SecretDetector pass over many fixtures

@Suite("SearchWeb — adversarial snippet redaction (100-fixture corpus)")
struct SearchWebSecretRedactionTests {

    @Test("Synthesized 100-snippet corpus: every embedded secret is redacted")
    func hundredSnippetCorpus() {
        // Build 100 distinct snippets each carrying one of several
        // secret-shaped tokens. After SecretDetector.scan, the original
        // raw token must NOT appear in the redacted output.
        struct Synth {
            let label: String
            let token: String
        }
        let synths: [Synth] = [
            Synth(label: "ANTHROPIC", token: "sk-ant-XXXXXXXXXXXXXXXXXXXXXXXXX1"),
            Synth(label: "OPENAI",    token: "sk-ABCDEFGHIJKLMNOPQRSTUVWX"),
            Synth(label: "OPENAI_PROJECT", token: "sk-proj-ABCDEFGHIJKLMNOPQRSTUVWX"),
            Synth(label: "GITHUB",    token: "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"),
            Synth(label: "AWS_KEYID", token: "AKIA1234567890ABCDEF"),
            Synth(label: "STRIPE",    token: "sk_live_ABCDEFGHIJKLMNOPQRSTUVWX"),
            Synth(label: "SLACK",     token: "xoxb-12345-67890-abcdef"),
            Synth(label: "NPM",       token: "npm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"),
            Synth(label: "HF",        token: "hf_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1"),
            Synth(label: "BEARER",    token: "bearer aaaaaaaaaaaaaaaaaaaa.bb.cc"),
        ]
        // 10 patterns × 10 wrapping templates = 100 fixtures.
        let templates: [String] = [
            "Result text — token <X> appears in body",
            "Pre-text \(String(repeating: "x", count: 20)) <X> after",
            "Inline (<X>) within parentheses",
            "List item: <X> ; another item",
            "Mixed: hello <X> world",
            "Blog headline featuring <X>",
            "Sentence ending with <X>.",
            "Quoted: \"<X>\" example",
            "Markdown `<X>` inline",
            "Hidden <X> at end of snippet",
        ]
        var fixtures = 0
        for synth in synths {
            for template in templates {
                fixtures += 1
                let raw = template.replacingOccurrences(of: "<X>", with: synth.token)
                let scanned = SecretDetector.scan(raw)
                #expect(!scanned.redacted.contains(synth.token),
                        "fixture \(fixtures) (\(synth.label)) leaked the raw token: \(scanned.redacted)")
                #expect(scanned.redacted.contains("[REDACTED:"),
                        "fixture \(fixtures) (\(synth.label)) had no [REDACTED:] tag")
            }
        }
        #expect(fixtures == 100)
    }
}

// MARK: - End-to-end via injected backend

@Suite("SearchWeb — end-to-end with injected backend (no network)")
struct SearchWebEndToEndTests {

    fileprivate struct ClosureBackend: SearchWebBackend {
        let html: String
        func fetch(url: URL) async throws -> String { html }
    }

    @Test("Tool returns formatted markdown with redacted snippets when backend serves Lite HTML")
    func endToEndRedacts() async {
        // Inject a backend whose snippet contains a secret-shaped token.
        // Result: tool output must redact the token.
        let leakedToken = "sk-ant-aaaaaaaaaaaaaaaaaaaaaa1A"
        let html = """
        <table>
        <tr><td class="result-link"><a rel="nofollow" class="result-link" href="https://example.com/post">Public Title</a></td></tr>
        <tr><td class="result-snippet">leaked: \(leakedToken) was checked in by accident</td></tr>
        </table>
        """
        let session = MCPSession(projectRoot: NSTemporaryDirectory())
        let result = await SearchWebTool.handle(
            arguments: ["query": .string("public topic")],
            session: session,
            backend: ClosureBackend(html: html)
        )

        #expect(result.isError != true)
        let text = result.content.compactMap { c -> String? in
            if case .text(let t, _, _) = c { return t } else { return nil }
        }.joined(separator: "\n")
        #expect(text.contains("Public Title"))
        #expect(text.contains("https://example.com/post"))
        #expect(text.contains("[REDACTED:ANTHROPIC_API_KEY]"))
        #expect(!text.contains(leakedToken))
    }

    @Test("Tool returns isError when guard-research blocks the query")
    func guardResearchBlocksAtToolBoundary() async {
        let session = MCPSession(projectRoot: NSTemporaryDirectory())
        let result = await SearchWebTool.handle(
            arguments: ["query": .string("dump /Users/clank/Library tokens")],
            session: session,
            backend: ClosureBackend(html: "")
        )
        #expect(result.isError == true)
        let text = result.content.compactMap { c -> String? in
            if case .text(let t, _, _) = c { return t } else { return nil }
        }.joined(separator: " ")
        #expect(text.contains("guard-research blocked"))
    }

    @Test("Redirect delegate refuses off-host redirects")
    func redirectDelegatePinsHost() async {
        let delegate = HostPinnedRedirectDelegate()
        let session = URLSession(configuration: .default)
        let dummyTask = session.dataTask(with: URL(string: "https://lite.duckduckgo.com/lite/")!)
        defer { dummyTask.cancel() }

        let response = HTTPURLResponse(
            url: URL(string: "https://lite.duckduckgo.com/lite/")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://evil.example.com/x"]
        )!
        let foreignRedirect = URLRequest(url: URL(string: "https://evil.example.com/x")!)
        var captured: URLRequest? = .some(URLRequest(url: URL(string: "x:")!))
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.urlSession(
                session, task: dummyTask,
                willPerformHTTPRedirection: response,
                newRequest: foreignRedirect
            ) { req in
                captured = req
                cont.resume()
            }
        }
        #expect(captured == nil, "off-host redirect should be cancelled (got \(String(describing: captured?.url)))")

        let onHostRedirect = URLRequest(url: URL(string: "https://lite.duckduckgo.com/lite/?p=2")!)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            delegate.urlSession(
                session, task: dummyTask,
                willPerformHTTPRedirection: response,
                newRequest: onHostRedirect
            ) { req in
                captured = req
                cont.resume()
            }
        }
        #expect(captured?.url?.host == "lite.duckduckgo.com")
    }

    @Test("Backend host allowlist rejects non-DDG host (defense in depth)")
    func hostAllowlistRejectsForeignHost() async {
        let backend = DuckDuckGoLiteBackend()
        let foreign = URL(string: "https://example.com/lite/?q=x")!
        do {
            _ = try await backend.fetch(url: foreign)
            Issue.record("expected hostNotAllowed throw for non-DDG host")
        } catch let e as SearchWebError {
            switch e {
            case .hostNotAllowed: break
            default: Issue.record("expected .hostNotAllowed, got \(e)")
            }
        } catch {
            Issue.record("expected SearchWebError, got \(error)")
        }
    }
}

// MARK: - Tool catalog wiring

@Suite("SearchWeb — Tool catalog")
struct SearchWebCatalogTests {

    @Test("ToolRouter advertises search_web with the documented schema")
    func toolListedInCatalog() {
        let tools = ToolRouter.allTools()
        let searchWeb = tools.first(where: { $0.name == "search_web" })
        #expect(searchWeb != nil)
        guard let tool = searchWeb else { return }
        #expect((tool.description ?? "").lowercased().contains("duckduckgo"))
        #expect((tool.description ?? "").lowercased().contains("guard-research"))
    }
}
