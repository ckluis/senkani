import SwiftUI
import AppKit
import SwiftTreeSitter
import Indexer

struct CodeEditorPane: View {
    @Bindable var pane: PaneModel
    @State private var fileContent: String = ""
    @State private var filePath: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // File bar
            HStack(spacing: 6) {
                TextField("File path...", text: $filePath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SenkaniTheme.paneBody)
                    .cornerRadius(3)
                    .onSubmit { openFile() }

                Button("Open") { openFile() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                Button(action: openFileDialog) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Browse files...")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)

            Divider()

            if fileContent.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(.system(size: 32))
                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                    Text("Enter a file path or click Open to view code")
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SenkaniTheme.paneBody)
            } else {
                HighlightedCodeView(
                    content: fileContent,
                    filePath: filePath
                )
            }
        }
    }

    private func openFile() {
        guard !filePath.isEmpty else { return }
        let path = filePath.hasPrefix("/") ? filePath : (pane.workingDirectory + "/" + filePath)
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            fileContent = "// Error: could not read \(path)"
            return
        }
        fileContent = content
        pane.previewFilePath = path
    }

    private func openFileDialog() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: pane.workingDirectory)
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            filePath = url.path
            openFile()
        }
    }
}

// MARK: - Highlighted Code View (NSTextView + tree-sitter)

struct HighlightedCodeView: NSViewRepresentable {
    let content: String
    let filePath: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = defaultTextColor
        textView.backgroundColor = bgColor
        textView.insertionPointColor = .white
        textView.isEditable = false
        textView.isSelectable = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 8)

        // Line numbers
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler

        scrollView.drawsBackground = true
        scrollView.backgroundColor = bgColor
        scrollView.scrollerStyle = .overlay

        applyContent(to: textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != content {
            applyContent(to: textView)
        }
    }

    private func applyContent(to textView: NSTextView) {
        let attributed = buildHighlightedString()
        textView.textStorage?.setAttributedString(attributed)
    }

    /// Parse with tree-sitter and build an NSAttributedString with syntax colors.
    private func buildHighlightedString() -> NSAttributedString {
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: defaultTextColor,
        ]

        let result = NSMutableAttributedString(string: content, attributes: defaultAttrs)

        let ext = (filePath as NSString).pathExtension.lowercased()
        guard let languageId = FileWalker.languageMap[ext],
              let tsLanguage = TreeSitterBackend.language(for: languageId) else {
            return result
        }

        guard let queryString = highlightQuery(for: languageId),
              let queryData = queryString.data(using: .utf8) else {
            return result
        }

        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return result }
        guard let tree = parser.parse(content) else { return result }
        guard let rootNode = tree.rootNode else { return result }
        guard let query = try? Query(language: tsLanguage, data: queryData) else { return result }

        let cursor = query.execute(node: rootNode, in: tree)
        let contentLength = (content as NSString).length

        for match in cursor {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let range = capture.range
                guard range.location >= 0, NSMaxRange(range) <= contentLength else { continue }

                let color = captureColor(for: name)
                result.addAttribute(.foregroundColor, value: color, range: range)
            }
        }

        return result
    }
}

// MARK: - Colors

private let bgColor = NSColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1.0)
private let defaultTextColor = NSColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1.0)
private let gutterBgColor = NSColor(red: 0.065, green: 0.065, blue: 0.065, alpha: 1.0)
private let gutterTextColor = NSColor(red: 0.361, green: 0.388, blue: 0.424, alpha: 1.0)

/// One Dark inspired palette, keyed by tree-sitter capture name prefix.
private func captureColor(for name: String) -> NSColor {
    let base = name.split(separator: ".").first.map(String.init) ?? name
    switch base {
    case "keyword":     return NSColor(red: 0.776, green: 0.471, blue: 0.867, alpha: 1.0)  // purple
    case "string":      return NSColor(red: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)  // green
    case "comment":     return NSColor(red: 0.361, green: 0.388, blue: 0.424, alpha: 1.0)  // gray
    case "function", "method":
                        return NSColor(red: 0.380, green: 0.686, blue: 0.878, alpha: 1.0)  // blue
    case "type":        return NSColor(red: 0.898, green: 0.753, blue: 0.424, alpha: 1.0)  // yellow
    case "number", "float":
                        return NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1.0)  // orange
    case "variable":    return NSColor(red: 0.878, green: 0.376, blue: 0.290, alpha: 1.0)  // red
    case "constant":    return NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1.0)  // orange
    case "operator":    return NSColor(red: 0.671, green: 0.698, blue: 0.745, alpha: 1.0)  // light gray
    case "property":    return NSColor(red: 0.878, green: 0.376, blue: 0.290, alpha: 1.0)  // red
    case "punctuation": return NSColor(red: 0.671, green: 0.698, blue: 0.745, alpha: 1.0)  // light gray
    case "include", "import":
                        return NSColor(red: 0.776, green: 0.471, blue: 0.867, alpha: 1.0)  // purple
    case "boolean":     return NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1.0)  // orange
    case "label":       return NSColor(red: 0.380, green: 0.686, blue: 0.878, alpha: 1.0)  // blue
    default:            return defaultTextColor
    }
}

// MARK: - Highlight Queries

private func highlightQuery(for language: String) -> String? {
    switch language {
    case "swift": return swiftHighlightsQuery
    default: return nil
    }
}

/// Minimal Swift highlights.scm compatible with tree-sitter-swift grammar.
private let swiftHighlightsQuery = """
"func" @keyword
"var" @keyword
"let" @keyword
"class" @keyword
"struct" @keyword
"enum" @keyword
"protocol" @keyword
"extension" @keyword
"import" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"guard" @keyword
"switch" @keyword
"case" @keyword
"default" @keyword
"for" @keyword
"while" @keyword
"repeat" @keyword
"in" @keyword
"where" @keyword
"throw" @keyword
"throws" @keyword
"try" @keyword
"catch" @keyword
"do" @keyword
"as" @keyword
"is" @keyword
"nil" @constant
"true" @boolean
"false" @boolean
"self" @variable
"Self" @type
"super" @variable
"init" @keyword
"deinit" @keyword
"typealias" @keyword
"associatedtype" @keyword
"static" @keyword
"private" @keyword
"fileprivate" @keyword
"internal" @keyword
"public" @keyword
"open" @keyword
"override" @keyword
"mutating" @keyword
"nonmutating" @keyword
"indirect" @keyword
"convenience" @keyword
"required" @keyword
"lazy" @keyword
"weak" @keyword
"unowned" @keyword
"async" @keyword
"await" @keyword
"some" @keyword
"any" @keyword
"inout" @keyword
"defer" @keyword
"break" @keyword
"continue" @keyword
"fallthrough" @keyword
(comment) @comment
(line_string_literal) @string
(multi_line_string_literal) @string
(integer_literal) @number
(real_literal) @number
(type_identifier) @type
"""

// MARK: - Line Number Ruler

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView!, orientation: .verticalRuler)
        self.ruleThickness = 40
        self.clientView = textView

        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(needsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: textView.enclosingScrollView?.contentView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func needsRedraw(_ note: Notification) { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        gutterBgColor.setFill()
        rect.fill()

        let visibleRect = textView.visibleRect
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        let string = textView.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: gutterTextColor,
        ]

        // Count lines before visible range
        var lineNumber = 1
        if visibleCharRange.location > 0 {
            let pre = string.substring(with: NSRange(location: 0, length: visibleCharRange.location))
            lineNumber = pre.components(separatedBy: "\n").count
        }

        var charIndex = visibleCharRange.location
        while charIndex < NSMaxRange(visibleCharRange) {
            let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)

            lineRect.origin.y -= visibleRect.origin.y
            lineRect.origin.y += textView.textContainerInset.height

            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: attrs)
            let drawPoint = NSPoint(
                x: ruleThickness - labelSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - labelSize.height) / 2
            )
            label.draw(at: drawPoint, withAttributes: attrs)

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}
