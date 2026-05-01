import Foundation

// MARK: - W.2 Markdown-first content negotiation
//
// Three-tier fallback ladder for fetching web content as cheaply as
// possible. Inspired by markdown.new (see
// `spec/inspirations/content-extraction/markdown-new.md`):
//
//   1. native    — `Accept: text/markdown` against the origin. If the
//                  response is markdown, return it directly.
//   2. transform — origin returned HTML; convert via `HTMLToMarkdown`.
//                  Default is a deterministic strip-tags transformer;
//                  the real Gemma-4 adapter wires in via DI (mirrors
//                  U.8 `ProseCadenceCompiler`).
//   3. render    — escalate to a JS-aware headless renderer
//                  (WebFetchEngine in MCP). The negotiator does NOT
//                  perform the render itself; it returns a
//                  `.needsRender` outcome so the caller can decide.
//
// Every successful fetch records:
//   - which tier handled it,
//   - the token estimate of the returned content,
//   - the input byte count from the origin (for compression metrics).
//
// Designed to live in Core with no MCP / WebKit dependency so it can
// be unit-tested without a real network.

public enum NegotiationTier: String, Sendable, Equatable {
    case native     // tier 1 — origin returned text/markdown
    case transform  // tier 2 — HTML→markdown transform
    case render     // tier 3 — caller must run a headless render
}

public enum NegotiationMethod: String, Sendable, Equatable {
    /// Default: try native → transform → render in order.
    case auto
    /// Skip tier 1; force the HTML→markdown transformer.
    case transform
    /// Skip tiers 1 + 2; the caller already knows the page is JS-bound.
    case render
}

/// Output of a content-negotiation attempt. `needsRender` carries the
/// raw HTML body (if available) so the caller can hand it to a
/// renderer with one fetch already paid for.
public struct ContentNegotiationResult: Sendable, Equatable {
    public let tier: NegotiationTier
    public let content: String
    public let tokensEstimate: Int
    public let originBytes: Int
    public let needsRender: Bool
    public let renderHint: String?

    public init(
        tier: NegotiationTier,
        content: String,
        tokensEstimate: Int,
        originBytes: Int,
        needsRender: Bool = false,
        renderHint: String? = nil
    ) {
        self.tier = tier
        self.content = content
        self.tokensEstimate = tokensEstimate
        self.originBytes = originBytes
        self.needsRender = needsRender
        self.renderHint = renderHint
    }
}

public enum ContentNegotiationError: Error, Equatable, Sendable {
    case originUnreachable(String)
    case allTiersFailed(String)
}

// MARK: - HTTP client abstraction (testable)

public struct HTTPFetchResponse: Sendable {
    public let body: Data
    public let contentType: String?
    public let statusCode: Int

    public init(body: Data, contentType: String?, statusCode: Int) {
        self.body = body
        self.contentType = contentType
        self.statusCode = statusCode
    }

    public var isMarkdownContentType: Bool {
        guard let ct = contentType?.lowercased() else { return false }
        // Accept text/markdown OR text/x-markdown OR text/plain;
        // markdown-flavored — origin signals "this is already what
        // you wanted." application/markdown is in the wild too.
        return ct.contains("text/markdown")
            || ct.contains("text/x-markdown")
            || ct.contains("application/markdown")
    }

    public var isHTMLContentType: Bool {
        guard let ct = contentType?.lowercased() else { return false }
        return ct.contains("text/html") || ct.contains("application/xhtml")
    }
}

public protocol ContentHTTPClient: Sendable {
    /// Fetch `url` with the given `Accept` header. Implementations are
    /// responsible for SSRF / host pinning / redirect policy — the
    /// negotiator trusts the response.
    func fetch(url: URL, accept: String) async throws -> HTTPFetchResponse
}

// MARK: - HTML→markdown transform (tier 2)

public protocol HTMLToMarkdown: Sendable {
    /// Convert HTML body bytes into a markdown string. Implementations
    /// SHOULD be deterministic for caching. May return nil to signal
    /// "transform unable to extract usefully — escalate to tier 3."
    func convert(html: String) -> String?
}

/// Default deterministic transformer. Strips scripts / styles / nav
/// boilerplate, preserves headings + paragraphs + list items + links.
/// Not a full HTML parser — good enough as a tier-2 default; the real
/// Gemma-4 adapter (or a `swift-html-to-markdown` adapter) replaces
/// this via DI when available.
public struct DeterministicHTMLToMarkdown: HTMLToMarkdown {
    public init() {}

    public func convert(html: String) -> String? {
        var body = html

        // Drop script/style/noscript blocks wholesale (case-insensitive,
        // greedy across newlines).
        for tag in ["script", "style", "noscript", "head", "svg"] {
            body = stripBlock(body, tag: tag)
        }

        // Headings: <h1>…</h1> → "# …"
        for level in 1...6 {
            let prefix = String(repeating: "#", count: level) + " "
            body = replaceTag(body, open: "h\(level)", close: "h\(level)") { inner in
                "\n\n\(prefix)\(inner.trimmingWhitespace())\n\n"
            }
        }

        // Lists: <li>…</li> → "- …"
        body = replaceTag(body, open: "li", close: "li") { inner in
            "\n- \(inner.trimmingWhitespace())"
        }

        // Paragraphs: <p>…</p> → blank-line-padded
        body = replaceTag(body, open: "p", close: "p") { inner in
            "\n\n\(inner.trimmingWhitespace())\n\n"
        }

        // Links: <a href="X">Y</a> → [Y](X). Naive — only handles the
        // `href="..."` attribute form; misses `href='...'` and bare
        // `href=...`. The Gemma-4 adapter handles those cases.
        body = replaceLinks(body)

        // <br> / <hr> → newlines
        body = body.replacingOccurrences(
            of: #"<br\s*/?>"#, with: "\n",
            options: .regularExpression
        )
        body = body.replacingOccurrences(
            of: #"<hr\s*/?>"#, with: "\n---\n",
            options: .regularExpression
        )

        // Strip every remaining tag.
        body = body.replacingOccurrences(
            of: #"<[^>]+>"#, with: "",
            options: .regularExpression
        )

        // Decode the most common HTML entities.
        body = body
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        // Collapse runs of >2 blank lines and trim.
        body = body.replacingOccurrences(
            of: #"\n{3,}"#, with: "\n\n",
            options: .regularExpression
        )
        body = body.trimmingCharacters(in: .whitespacesAndNewlines)

        return body.isEmpty ? nil : body
    }

    private func stripBlock(_ text: String, tag: String) -> String {
        let pattern = "<\(tag)(\\s[^>]*)?>[\\s\\S]*?</\(tag)>"
        return text.replacingOccurrences(
            of: pattern, with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private func replaceTag(
        _ text: String, open: String, close: String,
        _ transform: (String) -> String
    ) -> String {
        let pattern = "<\(open)(\\s[^>]*)?>([\\s\\S]*?)</\(close)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return text }

        let ns = text as NSString
        var result = ""
        var cursor = 0
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            let outer = match.range
            let inner = match.range(at: 2)
            if outer.location > cursor {
                result += ns.substring(with: NSRange(
                    location: cursor, length: outer.location - cursor))
            }
            let innerText = ns.substring(with: inner)
            result += transform(innerText)
            cursor = outer.location + outer.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(
                location: cursor, length: ns.length - cursor))
        }
        return result
    }

    private func replaceLinks(_ text: String) -> String {
        let pattern = #"<a\s[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        let range = NSRange(location: 0, length: ns.length)
        regex.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match, match.numberOfRanges >= 3 else { return }
            let outer = match.range
            let hrefR = match.range(at: 1)
            let textR = match.range(at: 2)
            if outer.location > cursor {
                result += ns.substring(with: NSRange(
                    location: cursor, length: outer.location - cursor))
            }
            let href = ns.substring(with: hrefR)
            let inner = ns.substring(with: textR).trimmingWhitespace()
            result += "[\(inner)](\(href))"
            cursor = outer.location + outer.length
        }
        if cursor < ns.length {
            result += ns.substring(with: NSRange(
                location: cursor, length: ns.length - cursor))
        }
        return result
    }
}

// MARK: - Token estimator

public enum FetchTokenEstimator {
    /// Approximate tokens-per-byte ratio used by the rest of Senkani
    /// (`SessionDatabase.recordMetrics` divides bytes by 4). Mirroring
    /// it here keeps the savings pane consistent across surfaces.
    public static func estimate(_ s: String) -> Int {
        max(1, s.utf8.count / 4)
    }
}

// MARK: - Markdown-first fetcher (orchestrator)

public struct MarkdownFirstFetcher: Sendable {
    private let httpClient: any ContentHTTPClient
    private let transformer: any HTMLToMarkdown

    public init(
        httpClient: any ContentHTTPClient,
        transformer: any HTMLToMarkdown = DeterministicHTMLToMarkdown()
    ) {
        self.httpClient = httpClient
        self.transformer = transformer
    }

    /// Run the three-tier ladder. `method` lets the caller force a
    /// tier — `auto` is the cheapest-first default.
    public func fetch(
        url: URL, method: NegotiationMethod = .auto
    ) async throws -> ContentNegotiationResult {
        switch method {
        case .render:
            // Caller already knows the page is JS-bound — short-circuit.
            return ContentNegotiationResult(
                tier: .render,
                content: "",
                tokensEstimate: 0,
                originBytes: 0,
                needsRender: true,
                renderHint: "method=render"
            )

        case .transform:
            let response = try await httpClient.fetch(
                url: url, accept: "text/html, text/markdown;q=0.9")
            return try escalateToTransform(response: response)

        case .auto:
            // Tier 1: native markdown.
            let response: HTTPFetchResponse
            do {
                response = try await httpClient.fetch(
                    url: url,
                    accept: "text/markdown, text/html;q=0.9, */*;q=0.5"
                )
            } catch {
                throw ContentNegotiationError.originUnreachable(
                    "tier 1 fetch failed: \(error)")
            }

            if response.isMarkdownContentType {
                let body = String(data: response.body, encoding: .utf8) ?? ""
                if !body.isEmpty {
                    return ContentNegotiationResult(
                        tier: .native,
                        content: body,
                        tokensEstimate: FetchTokenEstimator.estimate(body),
                        originBytes: response.body.count
                    )
                }
            }

            // Tier 2: HTML→markdown transform (reuse already-paid fetch).
            return try escalateToTransform(response: response)
        }
    }

    private func escalateToTransform(
        response: HTTPFetchResponse
    ) throws -> ContentNegotiationResult {
        // Only attempt transform on text bodies — escalate non-text
        // straight to render.
        guard let html = String(data: response.body, encoding: .utf8),
              !html.isEmpty
        else {
            return ContentNegotiationResult(
                tier: .render,
                content: "",
                tokensEstimate: 0,
                originBytes: response.body.count,
                needsRender: true,
                renderHint: "non-text or empty body"
            )
        }

        if let md = transformer.convert(html: html) {
            return ContentNegotiationResult(
                tier: .transform,
                content: md,
                tokensEstimate: FetchTokenEstimator.estimate(md),
                originBytes: response.body.count
            )
        }

        // Tier 3: caller must render. Hand the HTML back so a follow-up
        // renderer doesn't pay for another fetch.
        return ContentNegotiationResult(
            tier: .render,
            content: html,
            tokensEstimate: FetchTokenEstimator.estimate(html),
            originBytes: response.body.count,
            needsRender: true,
            renderHint: "transform produced no usable markdown"
        )
    }
}

// MARK: - Helpers

extension String {
    fileprivate func trimmingWhitespace() -> String {
        // Collapse interior whitespace runs to single spaces, trim edges.
        let collapsed = self.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
