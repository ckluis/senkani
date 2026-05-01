import Testing
import Foundation
@testable import Core

@Suite("ContentNegotiator (W.2 markdown-first fetch)")
struct ContentNegotiatorTests {

    // MARK: - Mock HTTP client

    /// Fixed-response HTTP client. Tests configure (contentType, body)
    /// to drive each tier.
    actor MockHTTPClient: ContentHTTPClient {
        private let response: HTTPFetchResponse?
        private let throwError: Error?
        private var observed: [(URL, String)] = []

        init(response: HTTPFetchResponse) {
            self.response = response
            self.throwError = nil
        }

        init(throwError: Error) {
            self.response = nil
            self.throwError = throwError
        }

        func fetch(url: URL, accept: String) async throws -> HTTPFetchResponse {
            observed.append((url, accept))
            if let throwError { throw throwError }
            return response!
        }

        func observedAccepts() -> [String] { observed.map { $0.1 } }
    }

    private struct DummyError: Error {}

    // MARK: - Tier 1: native markdown

    @Test func tierOneReturnsMarkdownDirectlyWhenOriginHonorsAccept() async throws {
        let body = """
        # Hello

        This page is already markdown — no transform needed.

        - one
        - two
        """
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(body.utf8),
            contentType: "text/markdown; charset=utf-8",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/post")!)

        #expect(result.tier == .native)
        #expect(result.needsRender == false)
        #expect(result.content == body)
        #expect(result.tokensEstimate == max(1, body.utf8.count / 4))
        #expect(result.originBytes == body.utf8.count)
    }

    @Test func tierOneAcceptHeaderPrefersMarkdown() async throws {
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data("# md".utf8),
            contentType: "text/markdown",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)
        _ = try await fetcher.fetch(url: URL(string: "https://example.com/")!)
        let accepts = await client.observedAccepts()
        #expect(accepts.count == 1)
        #expect(accepts[0].hasPrefix("text/markdown"))
    }

    // MARK: - Tier 2: HTML→markdown transform

    @Test func tierTwoFiresWhenOriginReturnsHTML() async throws {
        let html = """
        <!DOCTYPE html>
        <html><head><title>x</title><script>var leak=1;</script></head>
        <body>
        <h1>Welcome</h1>
        <p>This is the body of the article.</p>
        <ul><li>alpha</li><li>beta</li></ul>
        <p>See <a href="/next">the next page</a> for more.</p>
        </body></html>
        """
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(html.utf8),
            contentType: "text/html",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/post")!)

        #expect(result.tier == .transform)
        #expect(result.needsRender == false)
        #expect(result.content.contains("# Welcome"))
        #expect(result.content.contains("- alpha"))
        #expect(result.content.contains("[the next page](/next)"))
        #expect(!result.content.contains("var leak"))
        #expect(result.originBytes == html.utf8.count)
        #expect(result.tokensEstimate == max(1, result.content.utf8.count / 4))
    }

    // MARK: - Tier 3: render fallback

    @Test func tierThreeFiresWhenTransformerReturnsNil() async throws {
        // Transformer returns nil → escalate to render.
        struct NilTransformer: HTMLToMarkdown {
            func convert(html: String) -> String? { nil }
        }
        let html = "<html><body>opaque</body></html>"
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(html.utf8),
            contentType: "text/html",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(
            httpClient: client, transformer: NilTransformer())

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/")!)

        #expect(result.tier == .render)
        #expect(result.needsRender == true)
        #expect(result.content == html)  // raw HTML handed back to renderer
        #expect(result.renderHint != nil)
    }

    @Test func tierThreeFiresOnEmptyBody() async throws {
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(),
            contentType: "application/octet-stream",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/")!)

        #expect(result.tier == .render)
        #expect(result.needsRender == true)
        #expect(result.content.isEmpty)
    }

    // MARK: - Caller-forced tier

    @Test func methodRenderShortCircuitsBeforeAnyFetch() async throws {
        let client = MockHTTPClient(throwError: DummyError())  // would fail
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/")!,
            method: .render
        )

        #expect(result.tier == .render)
        #expect(result.needsRender == true)
        let accepts = await client.observedAccepts()
        #expect(accepts.isEmpty)  // proves no fetch was made
    }

    @Test func methodTransformSkipsNativeTier() async throws {
        // Even though origin advertises text/markdown, method=.transform
        // forces the HTML→md path.
        let html = "<h1>Forced</h1><p>Body.</p>"
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(html.utf8),
            contentType: "text/markdown",  // would normally trigger native
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/")!,
            method: .transform
        )

        #expect(result.tier == .transform)
        #expect(result.content.contains("# Forced"))
        let accepts = await client.observedAccepts()
        // Transform path advertises HTML preference.
        #expect(accepts[0].hasPrefix("text/html"))
    }

    // MARK: - Origin failure

    @Test func tierOneOriginErrorBecomesNegotiationError() async throws {
        let client = MockHTTPClient(throwError: DummyError())
        let fetcher = MarkdownFirstFetcher(httpClient: client)

        await #expect(throws: ContentNegotiationError.self) {
            _ = try await fetcher.fetch(
                url: URL(string: "https://example.com/")!)
        }
    }

    // MARK: - Acceptance #1 — ≥40 % token reduction on a fixture

    @Test func fortyPercentReductionOnFixtureCorpus() async throws {
        // Realistic fixture: a docs-style HTML page with prose plus
        // typical boilerplate (head, scripts, nav). The markdown-
        // equivalent body is ~3× smaller — well past the 40 % floor.
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
          <title>Senkani docs — fixture</title>
          <meta charset="utf-8">
          <meta name="description" content="docs page">
          <script src="/static/analytics.js"></script>
          <style>body{font-family:system-ui;margin:0}nav{padding:1em}</style>
        </head>
        <body>
          <nav><a href="/">Home</a> · <a href="/docs">Docs</a></nav>
          <main>
            <h1>Markdown-first fetch</h1>
            <p>The negotiator tries text/markdown first, then escalates
              to a HTML-to-markdown transform, then to a headless render.</p>
            <h2>Why three tiers?</h2>
            <p>Each tier is strictly more expensive and strictly more
              capable. Cheapest-correct-first is the right default.</p>
            <ul>
              <li>Tier 1: native markdown from the origin.</li>
              <li>Tier 2: deterministic HTML to markdown transform.</li>
              <li>Tier 3: WKWebView render (slow, JS-aware).</li>
            </ul>
            <p>See <a href="/spec">the spec</a> for details.</p>
          </main>
          <footer><script>track();</script>© 2026</footer>
        </body>
        </html>
        """
        let client = MockHTTPClient(response: HTTPFetchResponse(
            body: Data(html.utf8),
            contentType: "text/html",
            statusCode: 200
        ))
        let fetcher = MarkdownFirstFetcher(httpClient: client)
        let result = try await fetcher.fetch(
            url: URL(string: "https://example.com/")!)

        #expect(result.tier == .transform)
        let originTokens = max(1, html.utf8.count / 4)
        let outputTokens = result.tokensEstimate
        let reduction = Double(originTokens - outputTokens) / Double(originTokens)
        #expect(
            reduction >= 0.40,
            Comment(rawValue: "expected ≥40% token reduction; got " +
                "\(Int(reduction * 100))% (origin=\(originTokens) tokens, " +
                "transform=\(outputTokens) tokens)")
        )
    }

    // MARK: - Token estimator

    @Test func tokenEstimatorMatchesByteOverFour() {
        let s = String(repeating: "a", count: 4096)
        #expect(FetchTokenEstimator.estimate(s) == 1024)
        // Always at least 1 even for tiny strings.
        #expect(FetchTokenEstimator.estimate("x") == 1)
    }

    // MARK: - Deterministic HTML→md unit coverage

    @Test func deterministicTransformerStripsScriptAndPreservesHeadings() {
        let t = DeterministicHTMLToMarkdown()
        let html = "<script>x</script><h2>Heading</h2><p>Body.</p>"
        let md = t.convert(html: html) ?? ""
        #expect(md.contains("## Heading"))
        #expect(md.contains("Body."))
        #expect(!md.contains("script"))
        #expect(!md.contains("<"))
    }

    @Test func deterministicTransformerReturnsNilForEmptyHTML() {
        let t = DeterministicHTMLToMarkdown()
        // <body> with only stripped tags reduces to empty → nil signal.
        #expect(t.convert(html: "<style>x</style><script>y</script>") == nil)
    }
}
