import SwiftUI
import WebKit

/// Renders a markdown file in a WKWebView with live auto-reload.
struct MarkdownPreviewView: View {
    @Bindable var pane: PaneModel
    @State private var filePath: String = ""
    @State private var showFilePicker = false
    @State private var isDropTargeted = false
    @State private var pathError: String?

    var body: some View {
        if pane.previewFilePath.isEmpty {
            filePickerPrompt
        } else {
            WebViewRepresentable(filePath: pane.previewFilePath, mode: .markdown)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filePickerPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "doc.richtext")
                .font(.system(size: 40))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            Text("Markdown Preview")
                .font(.headline)
            Text("Choose a .md file to preview, or drag and drop")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("File path", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
                    .onSubmit { applyPath() }

                Button("Browse...") {
                    pickFile(types: ["md", "markdown", "txt"])
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 40)

            if let error = pathError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundStyle(.blue.opacity(0.5))
                    .padding(8)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func applyPath() {
        let expanded = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else {
            pathError = "File not found at: \(expanded)"
            return
        }
        pathError = nil
        pane.previewFilePath = expanded
    }

    private func pickFile(types: [String]) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = types.compactMap { .init(filenameExtension: $0) }
        if panel.runModal() == .OK, let url = panel.url {
            pane.previewFilePath = url.path
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
            if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                DispatchQueue.main.async {
                    pane.previewFilePath = url.path
                }
            }
        }
        return true
    }
}

// MARK: - WebView rendering mode

enum PreviewMode {
    case markdown
    case html
}

// MARK: - NSViewRepresentable wrapping WKWebView

struct WebViewRepresentable: NSViewRepresentable {
    let filePath: String
    let mode: PreviewMode

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // SECURITY: Configure WKWebView based on preview mode.
        // Markdown preview: disable JavaScript entirely — there is no legitimate
        // reason for JS in rendered markdown, and it prevents XSS from malicious .md files.
        // HTML preview: allow JavaScript (needed for interactive pages) but restrict
        // network access and file system access via Content Security Policy injected in HTML.
        switch mode {
        case .markdown:
            config.defaultWebpagePreferences.allowsContentJavaScript = false
        case .html:
            // JavaScript allowed for HTML preview; CSP is added in ensureHTMLHead
            config.defaultWebpagePreferences.allowsContentJavaScript = true
        }

        // SECURITY: Disable cross-origin resource sharing for all modes
        config.setValue(false, forKey: "allowUniversalAccessFromFileURLs")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.startWatching(path: filePath, mode: mode)
        loadContent(into: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coord = context.coordinator
        if coord.currentPath != filePath || coord.currentMode != mode {
            coord.stopWatching()
            coord.startWatching(path: filePath, mode: mode)
            loadContent(into: webView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func loadContent(into webView: WKWebView) {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
            webView.loadHTMLString(errorHTML("Cannot read file: \(filePath)"), baseURL: nil)
            return
        }

        switch mode {
        case .markdown:
            let html = Self.wrapMarkdownHTML(content)
            webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: (filePath as NSString).deletingLastPathComponent))
        case .html:
            let html = Self.ensureHTMLHead(content)
            webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: (filePath as NSString).deletingLastPathComponent))
        }
    }

    private func errorHTML(_ msg: String) -> String {
        // SECURITY: HTML-escape the message to prevent XSS via crafted file paths
        let escaped = msg.htmlEscaped
        return "<html><body style='font-family:system-ui;color:#999;padding:40px'>\(escaped)</body></html>"
    }

    // MARK: - Markdown to HTML conversion

    static func wrapMarkdownHTML(_ markdown: String) -> String {
        let bodyHTML = markdownToHTML(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src file: data:;">
        \(stylesheet)
        </head>
        <body>
        <article>\(bodyHTML)</article>
        </body>
        </html>
        """
    }

    /// Simple regex-based markdown-to-HTML converter.
    /// Handles: headers, bold, italic, inline code, code blocks, lists, links, blockquotes, hr, paragraphs.
    static func markdownToHTML(_ md: String) -> String {
        let lines = md.components(separatedBy: "\n")
        var html: [String] = []
        var inCodeBlock = false
        var codeLang = ""
        var codeLines: [String] = []
        var inList = false
        var listType = "" // "ul" or "ol"

        func closeList() {
            if inList {
                html.append("</\(listType)>")
                inList = false
            }
        }

        for line in lines {
            // Fenced code blocks
            if line.hasPrefix("```") {
                if inCodeBlock {
                    html.append("<pre><code class=\"language-\(codeLang)\">\(codeLines.joined(separator: "\n").htmlEscaped)</code></pre>")
                    codeLines = []
                    inCodeBlock = false
                    codeLang = ""
                } else {
                    closeList()
                    inCodeBlock = true
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock {
                codeLines.append(line)
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Empty line
            if trimmed.isEmpty {
                closeList()
                continue
            }

            // Horizontal rule
            if trimmed.range(of: #"^(\-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                closeList()
                html.append("<hr>")
                continue
            }

            // Headers
            if trimmed.range(of: #"^(#{1,6})\s+(.+)$"#, options: .regularExpression) != nil {
                closeList()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                html.append("<h\(level)>\(inlineMarkdown(text))</h\(level)>")
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                closeList()
                let text = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                html.append("<blockquote><p>\(inlineMarkdown(text))</p></blockquote>")
                continue
            }

            // Unordered list
            if trimmed.range(of: #"^[-*+]\s+(.+)$"#, options: .regularExpression) != nil {
                if !inList || listType != "ul" {
                    closeList()
                    html.append("<ul>")
                    inList = true
                    listType = "ul"
                }
                let text = String(trimmed.drop(while: { $0 == "-" || $0 == "*" || $0 == "+" || $0 == " " }))
                html.append("<li>\(inlineMarkdown(text))</li>")
                continue
            }

            // Ordered list
            if trimmed.range(of: #"^\d+\.\s+(.+)$"#, options: .regularExpression) != nil {
                if !inList || listType != "ol" {
                    closeList()
                    html.append("<ol>")
                    inList = true
                    listType = "ol"
                }
                let text = String(trimmed.drop(while: { $0 != " " }).dropFirst())
                html.append("<li>\(inlineMarkdown(text))</li>")
                continue
            }

            // Paragraph
            closeList()
            html.append("<p>\(inlineMarkdown(trimmed))</p>")
        }

        closeList()
        if inCodeBlock {
            html.append("<pre><code>\(codeLines.joined(separator: "\n").htmlEscaped)</code></pre>")
        }

        return html.joined(separator: "\n")
    }

    /// Convert inline markdown: bold, italic, code, links, images
    static func inlineMarkdown(_ text: String) -> String {
        var s = text.htmlEscaped

        // Images: ![alt](url)
        s = s.replacingOccurrences(
            of: #"!\[([^\]]*)\]\(([^)]+)\)"#,
            with: "<img src=\"$2\" alt=\"$1\" style=\"max-width:100%\">",
            options: .regularExpression
        )

        // Links: [text](url)
        s = s.replacingOccurrences(
            of: #"\[([^\]]+)\]\(([^)]+)\)"#,
            with: "<a href=\"$2\">$1</a>",
            options: .regularExpression
        )

        // Inline code
        s = s.replacingOccurrences(
            of: #"`([^`]+)`"#,
            with: "<code>$1</code>",
            options: .regularExpression
        )

        // Bold: **text** or __text__
        s = s.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"__(.+?)__"#,
            with: "<strong>$1</strong>",
            options: .regularExpression
        )

        // Italic: *text* or _text_
        s = s.replacingOccurrences(
            of: #"\*(.+?)\*"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: #"\b_(.+?)_\b"#,
            with: "<em>$1</em>",
            options: .regularExpression
        )

        return s
    }

    // MARK: - HTML preview helpers

    /// SECURITY: For HTML preview, we inject a CSP that allows scripts and styles
    /// (needed for interactive HTML) but blocks network requests to prevent data
    /// exfiltration. If the HTML already has a <head>, we inject the CSP meta tag
    /// into it; otherwise we wrap the content with a full head.
    static let htmlPreviewCSP = """
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src file: data: blob:; font-src file: data:;">
    """

    static func ensureHTMLHead(_ raw: String) -> String {
        let lower = raw.lowercased()
        if let headCloseRange = lower.range(of: "</head") {
            // SECURITY: Inject CSP before </head> to restrict network access
            let insertionPoint = raw.index(headCloseRange.lowerBound, offsetBy: 0)
            var modified = raw
            modified.insert(contentsOf: "\n\(htmlPreviewCSP)\n", at: insertionPoint)
            return modified
        }
        if lower.contains("<head") {
            // Has <head but no </head> — inject after first >
            if let headRange = lower.range(of: "<head"),
               let closeAngle = raw[headRange.upperBound...].firstIndex(of: ">") {
                var modified = raw
                let afterAngle = raw.index(after: closeAngle)
                modified.insert(contentsOf: "\n\(htmlPreviewCSP)\n", at: afterAngle)
                return modified
            }
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        \(htmlPreviewCSP)
        \(stylesheet)
        </head>
        <body>\(raw)</body>
        </html>
        """
    }

    // MARK: - Shared dark-mode stylesheet

    static let stylesheet = """
    <style>
    :root {
        color-scheme: light dark;
    }
    body {
        font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
        line-height: 1.6;
        padding: 24px 32px;
        max-width: 800px;
        margin: 0 auto;
        color: #1d1d1f;
        background: #ffffff;
    }
    @media (prefers-color-scheme: dark) {
        body {
            color: #e5e5e7;
            background: #1e1e1e;
        }
        a { color: #6cb4ff; }
        blockquote { border-color: #444; color: #aaa; }
        code { background: #2a2a2a; }
        pre { background: #1a1a1a; border-color: #333; }
        hr { border-color: #333; }
        table, th, td { border-color: #444; }
        th { background: #2a2a2a; }
    }
    h1, h2, h3, h4, h5, h6 {
        margin-top: 1.4em;
        margin-bottom: 0.5em;
        font-weight: 600;
    }
    h1 { font-size: 1.8em; border-bottom: 1px solid #ddd; padding-bottom: 0.3em; }
    h2 { font-size: 1.4em; border-bottom: 1px solid #eee; padding-bottom: 0.2em; }
    h3 { font-size: 1.2em; }
    p { margin: 0.8em 0; }
    a { color: #0066cc; text-decoration: none; }
    a:hover { text-decoration: underline; }
    code {
        font-family: 'SF Mono', Menlo, Monaco, 'Courier New', monospace;
        font-size: 0.9em;
        background: #f0f0f0;
        padding: 0.15em 0.35em;
        border-radius: 3px;
    }
    pre {
        background: #f6f6f6;
        border: 1px solid #e0e0e0;
        border-radius: 6px;
        padding: 14px 18px;
        overflow-x: auto;
        line-height: 1.45;
    }
    pre code {
        background: none;
        padding: 0;
        font-size: 0.85em;
    }
    blockquote {
        border-left: 3px solid #ccc;
        margin: 0.8em 0;
        padding: 0.2em 1em;
        color: #666;
    }
    ul, ol { padding-left: 1.8em; }
    li { margin: 0.3em 0; }
    hr {
        border: none;
        border-top: 1px solid #ddd;
        margin: 1.5em 0;
    }
    img { max-width: 100%; border-radius: 4px; }
    table {
        border-collapse: collapse;
        width: 100%;
        margin: 1em 0;
    }
    th, td {
        border: 1px solid #ddd;
        padding: 8px 12px;
        text-align: left;
    }
    th {
        background: #f6f6f6;
        font-weight: 600;
    }
    </style>
    """

    // MARK: - Coordinator with FSEvents file watcher

    class Coordinator {
        weak var webView: WKWebView?
        var currentPath: String = ""
        var currentMode: PreviewMode = .markdown
        private var source: DispatchSourceFileSystemObject?
        private var fileDescriptor: Int32 = -1

        func startWatching(path: String, mode: PreviewMode) {
            currentPath = path
            currentMode = mode

            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { return }
            fileDescriptor = fd

            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .rename, .attrib],
                queue: .global(qos: .utility)
            )

            src.setEventHandler { [weak self] in
                guard let self, let webView = self.webView else { return }
                guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return }

                Task { @MainActor in
                    let html: String
                    switch mode {
                    case .markdown:
                        html = WebViewRepresentable.wrapMarkdownHTML(content)
                    case .html:
                        html = WebViewRepresentable.ensureHTMLHead(content)
                    }
                    webView.loadHTMLString(html, baseURL: URL(fileURLWithPath: (path as NSString).deletingLastPathComponent))
                }
            }

            src.setCancelHandler {
                close(fd)
            }

            source = src
            src.resume()
        }

        func stopWatching() {
            source?.cancel()
            source = nil
            fileDescriptor = -1
        }

        deinit {
            stopWatching()
        }
    }
}

// MARK: - String HTML escaping

private extension String {
    var htmlEscaped: String {
        self.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
