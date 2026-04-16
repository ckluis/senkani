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

// MARK: - Redirect policy (Bach G4)

/// Pure, testable decision function for `WKNavigationDelegate.decidePolicyFor`.
///
/// The SSRF defense-in-depth has three phases (plus the pre-fetch DNS check in
/// `WebFetchTool.handle`):
///   1. Depth cap — max 5 redirects after the initial navigation.
///   2. Scheme allowlist on redirects — http/https only. Blocks `file://`,
///      `data:`, `javascript:` redirect bypass attempts.
///   3. DNS-resolved host check on redirects — blocks public-URL → private-IP
///      rebind (e.g. 3xx Location: http://10.0.0.1/).
///
/// The first navigation is trusted because `WebFetchTool.handle` already ran
/// the equivalent checks, AND integration tests use the engine directly with
/// `file://` fixtures which we intentionally allow at nav index 1.
enum RedirectPolicy {
    static let maxRedirects = 5

    enum Decision: Sendable, Equatable {
        case allow
        case cancel(WebFetchError)
    }

    static func decide(
        url: URL?,
        navigationIndex: Int,
        allowPrivate: Bool
    ) -> Decision {
        guard let url = url else { return .cancel(.invalidURL) }

        if navigationIndex > maxRedirects + 1 {
            return .cancel(.tooManyRedirects)
        }

        // First navigation is pre-validated by WebFetchTool.handle and may legitimately
        // be any scheme the caller supplied (integration test uses file:// fixtures).
        if navigationIndex == 1 {
            return .allow
        }

        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else {
            return .cancel(.invalidURL)
        }

        if !allowPrivate, let host = url.host, hostResolvesToPrivate(host) {
            return .cancel(.privateAddressBlocked)
        }

        return .allow
    }
}

// MARK: - Errors

enum WebFetchError: Error, LocalizedError, Equatable, Sendable {
    case timeout
    case invalidURL
    case disabled
    case privateAddressBlocked
    case tooManyRedirects

    var errorDescription: String? {
        switch self {
        case .timeout:
            return "Page load timed out. The site may require auth or block automation. " +
                   "For REST APIs try: senkani_exec(\"curl -s <url>\")"
        case .invalidURL:
            return "URL must begin with http:// or https://. For local files use senkani_read."
        case .disabled:
            return "senkani_web is disabled (SENKANI_WEB=off)."
        case .privateAddressBlocked:
            return "Private/link-local address blocked by SSRF guard (set SENKANI_WEB_ALLOW_PRIVATE=on to override for trusted internal docs servers)."
        case .tooManyRedirects:
            return "Redirect chain exceeded 5 hops — aborting to avoid loops and SSRF bypass via redirect."
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
    private let allowPrivate: Bool
    private var navigationCount = 0
    /// Initial URL + up to 5 redirects = 6 total navigations permitted.
    private static let maxRedirects = 5

    init(
        timeout: TimeInterval,
        format: String = "tree",
        allowPrivate: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        self.format = format
        self.allowPrivate = allowPrivate
        self.completion = completion
        super.init()
        // Schedule timeout on the RunLoop (we're always on the main thread here)
        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            self?.resumeOnce(.failure(WebFetchError.timeout))
        }
    }

    /// SSRF defense-in-depth: validate every navigation (including 3xx redirects).
    /// The initial URL was already validated by WebFetchTool.handle before we got here,
    /// but redirects can switch scheme (https → file://) or host (public → private IP).
    ///
    /// Bach G4: the policy logic is extracted into `RedirectPolicy.decide` so tests
    /// can exercise it without mocking WKNavigationAction. This method is now a thin
    /// adapter: compute decision, propagate failure into the completion, hand result
    /// back to WebKit.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        navigationCount += 1
        let url = navigationAction.request.url
        switch RedirectPolicy.decide(
            url: url,
            navigationIndex: navigationCount,
            allowPrivate: allowPrivate
        ) {
        case .allow:
            decisionHandler(.allow)
        case .cancel(let err):
            resumeOnce(.failure(err))
            decisionHandler(.cancel)
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
    nonisolated func fetch(
        url: URL,
        timeoutSeconds: Int,
        format: String = "tree",
        allowPrivate: Bool = false
    ) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor [self] in
                let wv = getOrCreateWebView()
                let handler = NavigationHandler(
                    timeout: Double(timeoutSeconds),
                    format: format,
                    allowPrivate: allowPrivate
                ) { result in
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

/// Check whether a 32-bit IPv4 address (network byte order in `netOrder`) is in a
/// private / link-local / reserved range. Loopback (127.0.0.0/8) is intentionally
/// NOT reported private — developer use case.
private func isPrivateIPv4(_ netOrder: UInt32) -> Bool {
    let host = UInt32(bigEndian: netOrder)
    let a = UInt8((host >> 24) & 0xff)
    let b = UInt8((host >> 16) & 0xff)
    if a == 127 { return false }                        // loopback allowed
    if a == 0 { return true }                           // 0.0.0.0/8 unspecified/reserved
    if a == 10 { return true }                          // 10.0.0.0/8
    if a == 172 && (16...31).contains(b) { return true }  // 172.16.0.0/12
    if a == 192 && b == 168 { return true }             // 192.168.0.0/16
    if a == 169 && b == 254 { return true }             // 169.254.0.0/16 link-local
    if a == 100 && (64...127).contains(b) { return true } // 100.64.0.0/10 CGNAT
    if a >= 224 { return true }                         // multicast + reserved
    return false
}

/// Check whether 16 IPv6 bytes are in a private / link-local / reserved range.
/// Loopback (::1) is intentionally NOT reported private. Recognizes IPv4-mapped
/// (::ffff:x.y.z.w) and IPv4-compatible (::x.y.z.w, deprecated) forms.
private func isPrivateIPv6(_ b: [UInt8]) -> Bool {
    guard b.count == 16 else { return true }
    // IPv4-mapped: ::ffff:A.B.C.D
    if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {
        let v4 = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
        return isPrivateIPv4(v4.bigEndian)
    }
    // IPv4-compatible (deprecated): ::A.B.C.D with A.B.C.D != 0.0.0.1 (loopback).
    if b[0..<12].allSatisfy({ $0 == 0 }) {
        let tail = Array(b[12..<16])
        if tail == [0, 0, 0, 0] { return true }              // ::/128 unspecified
        if tail == [0, 0, 0, 1] { return false }             // ::1 loopback allowed
        // Any other ::A.B.C.D is deprecated / likely a bypass attempt — block.
        return true
    }
    if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return true }  // fe80::/10 link-local
    if (b[0] & 0xfe) == 0xfc { return true }                   // fc00::/7 ULA
    if b[0] == 0xff { return true }                            // ff00::/8 multicast
    return false
}

/// String-level SSRF check against IP literals. Now covers:
///   - Dotted-decimal IPv4 via inet_pton.
///   - IPv6 (including IPv4-mapped ::ffff:x.y.z.w and IPv4-compatible ::x.y.z.w).
///   - IPv6 bracket notation.
/// Does NOT resolve hostnames — use `hostResolvesToPrivate` for that.
/// Kept for backward compatibility with unit tests.
func isPrivateHost(_ host: String) -> Bool {
    let h = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host

    // IPv4 literal
    var v4 = in_addr()
    if inet_pton(AF_INET, h, &v4) == 1 {
        return isPrivateIPv4(v4.s_addr)
    }

    // IPv6 literal
    var v6 = in6_addr()
    if inet_pton(AF_INET6, h, &v6) == 1 {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: v6) { raw in
            for i in 0..<16 { bytes[i] = raw[i] }
        }
        return isPrivateIPv6(bytes)
    }

    // Not an IP literal (hostname) — string-level check cannot decide; caller should
    // run `hostResolvesToPrivate` for DNS-backed resolution.
    return false
}

/// Resolve `host` via getaddrinfo and return true if ANY resolved address is private.
/// Fails closed on resolution error (returns true) — a host that does not resolve
/// cannot legitimately be reached, and refusing to fetch prevents DNS-rebind-shaped
/// attacks where the attacker controls intermittent resolution.
func hostResolvesToPrivate(_ host: String) -> Bool {
    let h = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast())
        : host

    // Fast path: IP literal — skip DNS.
    if isPrivateHost(h) { return true }
    // Also need to detect public IP literals so we don't call DNS on them.
    var v4 = in_addr()
    var v6 = in6_addr()
    if inet_pton(AF_INET, h, &v4) == 1 { return isPrivateIPv4(v4.s_addr) }
    if inet_pton(AF_INET6, h, &v6) == 1 {
        var bytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: v6) { raw in for i in 0..<16 { bytes[i] = raw[i] } }
        return isPrivateIPv6(bytes)
    }

    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(h, nil, &hints, &result)
    guard status == 0, let head = result else {
        // Resolution failure: fail closed.
        return true
    }
    defer { freeaddrinfo(head) }

    var node: UnsafeMutablePointer<addrinfo>? = head
    while let n = node {
        if let saPtr = n.pointee.ai_addr {
            switch Int32(saPtr.pointee.sa_family) {
            case AF_INET:
                let sin = UnsafeRawPointer(saPtr).assumingMemoryBound(to: sockaddr_in.self)
                if isPrivateIPv4(sin.pointee.sin_addr.s_addr) { return true }
            case AF_INET6:
                let sin6 = UnsafeRawPointer(saPtr).assumingMemoryBound(to: sockaddr_in6.self)
                var bytes = [UInt8](repeating: 0, count: 16)
                withUnsafeBytes(of: sin6.pointee.sin6_addr) { raw in
                    for i in 0..<16 { bytes[i] = raw[i] }
                }
                if isPrivateIPv6(bytes) { return true }
            default:
                break
            }
        }
        node = n.pointee.ai_next
    }
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

        // URL validation: http or https only. file:// dropped — local files go through
        // senkani_read, which has the full ProjectSecurity guard. file:// via the web
        // tool was an LLM-exfiltration path (redirect chains, prompt injection).
        guard let urlStr = arguments?["url"]?.stringValue,
              let url    = URL(string: urlStr),
              let scheme = url.scheme,
              ["http", "https"].contains(scheme)
        else {
            return .init(
                content: [.text(text: WebFetchError.invalidURL.errorDescription!, annotations: nil, _meta: nil)],
                isError: true
            )
        }

        // SSRF guard: DNS-resolve the host, reject if ANY address is private/link-local.
        // Loopback (127.0.0.0/8, ::1) intentionally allowed — developer use case.
        // Set SENKANI_WEB_ALLOW_PRIVATE=on to bypass (e.g. internal docs servers).
        let allowPrivate = ProcessInfo.processInfo.environment["SENKANI_WEB_ALLOW_PRIVATE"]?.lowercased() == "on"
        if !allowPrivate, let host = url.host, hostResolvesToPrivate(host) {
            Logger.log("web.ssrf.blocked", fields: [
                "tool": .string("web"),
                "host": .string(host),
                "outcome": .string("blocked")
            ])
            return .init(
                content: [.text(
                    text: WebFetchError.privateAddressBlocked.errorDescription!,
                    annotations: nil, _meta: nil)],
                isError: true
            )
        }

        let timeout = min(60, max(5, arguments?["timeout"]?.intValue ?? 15))
        let format  = arguments?["format"]?.stringValue ?? "tree"

        do {
            let markdown = try await WebFetchEngine.shared.fetch(
                url: url, timeoutSeconds: timeout, format: format, allowPrivate: allowPrivate)

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
