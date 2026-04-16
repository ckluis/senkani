import Foundation
import WebKit
import MCP
import Core

// MARK: - JavaScript: SPA settle polling (callAsyncJavaScript awaits the Promise)

private let settleJS = """
new Promise(function(resolve) {
  var polls = 0;
  (function check() {
    if (document.readyState === 'complete' && polls >= 1) { resolve(); return; }
    if (++polls > 10) { resolve(); return; }
    setTimeout(check, 200);
  })();
})
"""

// MARK: - JavaScript: plain-text extraction (format:"text")

private let innerTextJS = """
(function() {
  var text = (document.body || document.documentElement).innerText || '';
  return JSON.stringify({
    title: document.title,
    url: location.href,
    text: text,
    rawLen: document.documentElement.outerHTML.length
  });
})()
"""

// MARK: - JavaScript: semantic DOM extraction → JSON

private let axTreeJS = """
(function() {
  var nodes = [];
  var skip = ['script','style','svg','path','noscript','head','meta','link','br','hr'];
  var keep = ['h1','h2','h3','h4','h5','h6','p','li','td','th','dt','dd',
               'a','button','input','select','textarea','label','article',
               'section','nav','header','footer','main','blockquote'];
  var walker = document.createTreeWalker(
    document.body || document.documentElement,
    NodeFilter.SHOW_ELEMENT,
    { acceptNode: function(n) {
        var t = n.tagName.toLowerCase();
        if (skip.indexOf(t) >= 0) return NodeFilter.FILTER_REJECT;
        if (keep.indexOf(t) >= 0) return NodeFilter.FILTER_ACCEPT;
        if (n.getAttribute('role')) return NodeFilter.FILTER_ACCEPT;
        return NodeFilter.FILTER_SKIP;
    }}
  );
  var node; var count = 0;
  while ((node = walker.nextNode()) && count < 400) {
    var text = (node.innerText || node.textContent || '').trim().replace(/\\s+/g,' ').substring(0, 300);
    if (!text) continue;
    var obj = {tag: node.tagName.toLowerCase(), text: text};
    var href  = node.getAttribute('href');
    var role  = node.getAttribute('role');
    var label = node.getAttribute('aria-label') || node.getAttribute('placeholder');
    var type  = node.getAttribute('type');
    if (href)  obj.href  = href;
    if (role)  obj.role  = role;
    if (label) obj.label = label;
    if (type)  obj.type  = type;
    nodes.push(obj); count++;
  }
  var rawLen = document.documentElement.outerHTML.length;
  return JSON.stringify({title: document.title, url: location.href, nodes: nodes, rawLen: rawLen});
})()
"""

// MARK: - AXTree Formatter (pure function — testable without WKWebView)

enum AXTreeFormatter {
    /// Convert the JSON produced by axTreeJS into Markdown.
    /// Returns (markdown, rawHTMLBytes, nodeCount).
    static func format(jsonString: String) -> (markdown: String, rawBytes: Int, nodeCount: Int) {
        guard let data = jsonString.data(using: .utf8),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return ("// Could not parse page content\n", 0, 0)
        }

        let title    = obj["title"]  as? String       ?? ""
        let finalURL = obj["url"]    as? String       ?? ""
        let nodes    = obj["nodes"]  as? [[String: Any]] ?? []
        let rawBytes = obj["rawLen"] as? Int          ?? 0

        var lines: [String] = []

        // Auth wall detection
        let hasPassword = nodes.contains {
            ($0["type"]  as? String ?? "") == "password" ||
            ($0["label"] as? String ?? "").lowercased().contains("password")
        }
        if hasPassword {
            lines.append("[Warning: This page appears to require authentication.]")
            lines.append("")
        }

        for node in nodes {
            let tag   = node["tag"]   as? String ?? ""
            let text  = node["text"]  as? String ?? ""
            let href  = node["href"]  as? String
            let label = node["label"] as? String ?? ""

            switch tag {
            case "h1":                         lines.append("# \(text)")
            case "h2":                         lines.append("## \(text)")
            case "h3":                         lines.append("### \(text)")
            case "h4", "h5", "h6":             lines.append("#### \(text)")
            case "a" where !(href ?? "").isEmpty: lines.append("[\(text)](\(href!))")
            case "a":                          lines.append("[\(text)]")
            case "button":                     lines.append("[button] \(text)")
            case "input", "textarea", "select": lines.append("[input] \(label.isEmpty ? text : label)")
            case "li":                         lines.append("- \(text)")
            case "td", "th":                   lines.append("| \(text) |")
            default:                           if !text.isEmpty { lines.append(text) }
            }
        }

        let body    = lines.joined(separator: "\n")
        let axBytes = body.utf8.count
        let savedPct = rawBytes > 0
            ? String(format: "%.1f", Double(rawBytes - axBytes) / Double(rawBytes) * 100)
            : "?"

        var header = "// senkani_web: \(finalURL)\n"
        if !title.isEmpty { header += "// title: \"\(title)\"\n" }
        header += "// \(nodes.count) nodes extracted (raw HTML: \(rawBytes) bytes, saved \(savedPct)%)\n"
        header += "// format: AXTree — headings, paragraphs, links, buttons, form fields\n\n"

        return (header + body, rawBytes, nodes.count)
    }
}

// MARK: - Errors

enum WebFetchError: Error, LocalizedError {
    case timeout
    case invalidURL
    case disabled

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Page load timed out. The site may require auth or block automation. " +
                   "For REST APIs try: senkani_exec(\"curl -s <url>\")"
        case .invalidURL:
            return "URL must begin with http:// or https://. For local files use file:// prefix."
        case .disabled:
            return "senkani_web is disabled (SENKANI_WEB=off)."
        }
    }
}

// MARK: - Navigation Delegate

/// WKNavigationDelegate that bridges WebKit callbacks into a Swift continuation.
/// `resumeOnce()` ensures exactly one resume regardless of how many delegate
/// methods fire (redirect chains can trigger both didFinish and didFail).
/// Marked @MainActor because WKNavigationDelegate callbacks are always on the main thread
/// and WKWebView methods require main-actor isolation on macOS 14+.
@MainActor
private final class NavigationHandler: NSObject, WKNavigationDelegate {
    private var resumed = false
    private var timer: Timer?
    let completion: (Result<String, Error>) -> Void

    private let format: String

    init(timeout: TimeInterval, format: String = "tree", completion: @escaping (Result<String, Error>) -> Void) {
        self.format = format
        self.completion = completion
        super.init()
        // Schedule timeout on the RunLoop (we're always on the main thread here)
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.resumeOnce(.failure(WebFetchError.timeout))
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation?) {
        // Wait for SPA JS to finish rendering (polls readyState every 200ms, up to 2s)
        webView.callAsyncJavaScript(
            settleJS, arguments: [:], in: nil, in: .page
        ) { [weak self, weak webView] _ in
            guard let self = self, let webView = webView else { return }
            if self.format == "text" {
                // Plain text: return document.body.innerText — no Markdown structure
                webView.evaluateJavaScript(innerTextJS) { result, error in
                    if let err = error { self.resumeOnce(.failure(err)); return }
                    let json = result as? String ?? "{}"
                    guard let data = json.data(using: .utf8),
                          let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else {
                        self.resumeOnce(.success("// Could not extract page text\n"))
                        return
                    }
                    let title    = obj["title"]  as? String ?? ""
                    let finalURL = obj["url"]    as? String ?? ""
                    let text     = obj["text"]   as? String ?? ""
                    let rawLen   = obj["rawLen"] as? Int    ?? 0
                    let textBytes = text.utf8.count
                    let savedPct  = rawLen > 0
                        ? String(format: "%.1f", Double(rawLen - textBytes) / Double(rawLen) * 100)
                        : "?"
                    var header = "// senkani_web: \(finalURL)\n"
                    if !title.isEmpty { header += "// title: \"\(title)\"\n" }
                    header += "// format: text (plain innerText, raw HTML: \(rawLen) bytes, saved \(savedPct)%)\n\n"
                    self.resumeOnce(.success(header + text))
                }
            } else {
                // tree (default): extract semantic DOM nodes as AXTree Markdown
                webView.evaluateJavaScript(axTreeJS) { result, error in
                    if let err = error {
                        self.resumeOnce(.failure(err))
                        return
                    }
                    let json       = result as? String ?? "{}"
                    let (md, _, _) = AXTreeFormatter.format(jsonString: json)
                    self.resumeOnce(.success(md))
                }
            }
        }
    }

    func webView(_ _: WKWebView, didFail _: WKNavigation?, withError error: Error) {
        resumeOnce(.failure(error))
    }

    func webView(_ _: WKWebView, didFailProvisionalNavigation _: WKNavigation?, withError error: Error) {
        resumeOnce(.failure(error))
    }

    private func resumeOnce(_ result: Result<String, Error>) {
        guard !resumed else { return }
        resumed = true
        timer?.invalidate()
        timer = nil
        completion(result)
    }
}

// MARK: - WebFetchEngine (singleton, WKWebView reused across calls)

/// Process-global singleton. Reuses a single WKWebView so the WebKit XPC subprocess
/// is spawned at most once per MCP server process lifetime.
/// Marked @MainActor because all WKWebView operations require main-actor isolation.
@MainActor
final class WebFetchEngine {
    static let shared = WebFetchEngine()

    private var webView: WKWebView?
    private var currentHandler: NavigationHandler?  // strong-retained during navigation

    /// Pre-warm: create the WKWebView on the main actor, spawning the WebKit
    /// XPC subprocess. Call once at session start so first tool call is not slow.
    func warmUp() {
        _ = getOrCreateWebView()
        FileHandle.standardError.write(
            Data("[MCP] WebFetchEngine warmed up (WebKit XPC subprocess ready)\n".utf8))
    }

    private func getOrCreateWebView() -> WKWebView {
        if let wv = webView { return wv }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = .all
        let wv = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
            configuration: config
        )
        webView = wv
        return wv
    }

    /// Fetch `url` with JS execution and return output in the requested format.
    /// Must be called from a non-isolated async context; hops to MainActor internally.
    nonisolated func fetch(url: URL, timeoutSeconds: Int, format: String = "tree") async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [self] in
                let wv = getOrCreateWebView()
                let handler = NavigationHandler(timeout: Double(timeoutSeconds), format: format) { result in
                    switch result {
                    case .success(let s): continuation.resume(returning: s)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }
                currentHandler = handler     // prevent ARC dealloc
                wv.navigationDelegate = handler
                wv.load(URLRequest(
                    url: url,
                    cachePolicy: .reloadIgnoringLocalCacheData,
                    timeoutInterval: Double(timeoutSeconds)
                ))
            }
        }
    }
}

// MARK: - SSRF Helper

/// Returns true if the host resolves to a private / link-local range that should
/// be blocked to prevent Server-Side Request Forgery attacks.
/// Localhost (127.x, ::1) is intentionally NOT blocked — developer use case.
func isPrivateHost(_ host: String) -> Bool {
    // Strip IPv6 brackets if present
    let h = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host

    // IPv6 loopback is allowed; site-local fc/fd and link-local fe80 are not
    if h == "::1" { return false }
    if h.lowercased().hasPrefix("fe80") { return true }   // link-local
    if h.lowercased().hasPrefix("fc") || h.lowercased().hasPrefix("fd") { return true }  // ULA

    // Parse dotted-decimal IPv4
    let parts = h.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }  // hostname — DNS lookup not done here

    let a = parts[0], b = parts[1]
    if a == 10 { return true }                         // 10.0.0.0/8
    if a == 172 && (16...31).contains(b) { return true } // 172.16.0.0/12
    if a == 192 && b == 168 { return true }            // 192.168.0.0/16
    if a == 169 && b == 254 { return true }            // 169.254.0.0/16 link-local
    if a == 100 && (64...127).contains(b) { return true } // 100.64.0.0/10 CGNAT
    return false
}

// MARK: - Tool Handler

enum WebFetchTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) async -> CallTool.Result {
        // Feature gate: SENKANI_WEB=off disables the tool
        guard ProcessInfo.processInfo.environment["SENKANI_WEB"]?.lowercased() != "off" else {
            return .init(
                content: [.text(text: WebFetchError.disabled.errorDescription!, annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // URL validation: http, https, or file only
        guard let urlStr = arguments?["url"]?.stringValue,
              let url    = URL(string: urlStr),
              let scheme = url.scheme,
              ["http", "https", "file"].contains(scheme)
        else {
            return .init(
                content: [.text(text: WebFetchError.invalidURL.errorDescription!, annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // SSRF guard: block RFC 1918 + link-local ranges by default.
        // Localhost (127.x / ::1) is allowed for developer use.
        // Set SENKANI_WEB_ALLOW_PRIVATE=on to bypass (e.g. internal docs servers).
        let allowPrivate = ProcessInfo.processInfo.environment["SENKANI_WEB_ALLOW_PRIVATE"]?.lowercased() == "on"
        if !allowPrivate, let host = url.host {
            if isPrivateHost(host) {
                return .init(
                    content: [.text(
                        text: "Private network addresses are blocked by default (SENKANI_WEB_ALLOW_PRIVATE=on to override).",
                        annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }

        let timeout = min(60, max(5, arguments?["timeout"]?.intValue ?? 15))
        let format  = arguments?["format"]?.stringValue ?? "tree"

        do {
            let markdown = try await WebFetchEngine.shared.fetch(url: url, timeoutSeconds: timeout, format: format)

            // html format: always sandbox regardless of line count (HTML is always large)
            if format == "html" {
                guard let sid = session.sessionId else {
                    return .init(
                        content: [.text(text: "No session ID — cannot sandbox html output", annotations: nil, _meta: nil)],
                        isError: true
                    )
                }
                let lc = markdown.components(separatedBy: "\n").count
                let resultId = SessionDatabase.shared.storeSandboxedResult(
                    sessionId: sid, command: urlStr, output: markdown)
                let summary = Core.buildSandboxSummary(
                    output: markdown, lineCount: lc, byteCount: markdown.utf8.count, resultId: resultId)
                session.recordMetrics(
                    rawBytes: markdown.utf8.count, compressedBytes: summary.utf8.count,
                    feature: "web_fetch", command: urlStr, outputPreview: String(markdown.prefix(200)))
                return .init(content: [.text(text: summary, annotations: nil, _meta: nil)])
            }

            // tree / text: secrets + injection filter pass
            var output = markdown
            if session.secretsEnabled || session.injectionGuardEnabled {
                let cfg = FeatureConfig(
                    filter: false, secrets: session.secretsEnabled, indexer: false,
                    terse: false, injectionGuard: session.injectionGuardEnabled)
                let result = FilterPipeline(config: cfg).process(command: urlStr, output: markdown)
                output = result.output
                session.recordMetrics(
                    rawBytes: result.rawBytes, compressedBytes: result.filteredBytes,
                    feature: "web_fetch", command: urlStr, outputPreview: String(output.prefix(200)))
            } else {
                session.recordMetrics(
                    rawBytes: output.utf8.count, compressedBytes: output.utf8.count,
                    feature: "web_fetch", command: urlStr, outputPreview: String(output.prefix(200)))
            }

            // Sandbox if output exceeds threshold
            let lc = output.components(separatedBy: "\n").count
            if lc > sandboxLineThreshold, let sid = session.sessionId {
                let resultId = SessionDatabase.shared.storeSandboxedResult(
                    sessionId: sid, command: urlStr, output: output)
                let summary = Core.buildSandboxSummary(
                    output: output, lineCount: lc, byteCount: output.utf8.count, resultId: resultId)
                return .init(content: [.text(text: summary, annotations: nil, _meta: nil)])
            }

            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])

        } catch let e as WebFetchError {
            return .init(
                content: [.text(text: e.errorDescription!, annotations: nil, _meta: nil)],
                isError: true
            )
        } catch {
            return .init(
                content: [.text(
                    text: "Navigation failed: \(error.localizedDescription). " +
                          "A 403/404 response or network block may be the cause.",
                    annotations: nil, _meta: nil)],
                isError: true
            )
        }
    }
}
