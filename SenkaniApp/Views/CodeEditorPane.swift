import SwiftUI
import AppKit
import SwiftTreeSitter
import Indexer

struct CodeEditorPane: View {
    @Bindable var pane: PaneModel
    @State private var fileContent: String = ""
    @State private var filePath: String = ""
    @State private var isModified: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // File bar
            HStack(spacing: 6) {
                // Modified indicator
                if isModified {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }

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

                if isModified {
                    Button("Save") { saveFile() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .keyboardShortcut("s", modifiers: .command)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneBody)

            Divider()

            if fileContent.isEmpty && !isModified {
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
                    content: $fileContent,
                    filePath: filePath,
                    isModified: $isModified,
                    projectRoot: pane.workingDirectory,
                    onSave: { saveFile() },
                    onNavigate: { entry in navigateToSymbol(entry) }
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
        isModified = false
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

    private func saveFile() {
        let path = filePath.hasPrefix("/") ? filePath : (pane.workingDirectory + "/" + filePath)
        guard !path.isEmpty else { return }
        do {
            try fileContent.write(toFile: path, atomically: true, encoding: .utf8)
            isModified = false
        } catch {
            // Save failed silently — file bar still shows modified dot
        }
    }

    private func navigateToSymbol(_ entry: IndexEntry) {
        let absPath = entry.file.hasPrefix("/")
            ? entry.file
            : (pane.workingDirectory + "/" + entry.file)
        filePath = absPath
        guard let content = try? String(contentsOfFile: absPath, encoding: .utf8) else { return }
        fileContent = content
        isModified = false
        pane.previewFilePath = absPath

        // Post notification to scroll to the target line
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .codeEditorScrollToLine,
                object: nil,
                userInfo: ["line": entry.startLine]
            )
        }
    }
}

// MARK: - Notification for scroll-to-line

extension Notification.Name {
    static let codeEditorScrollToLine = Notification.Name("codeEditorScrollToLine")
}

// MARK: - Clickable Text View (Cmd+click support)

final class ClickableTextView: NSTextView {
    var onSymbolClick: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            if let word = wordAt(index: charIndex) {
                onSymbolClick?(word)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let point = convert(event.locationInWindow, from: nil)
            let charIndex = characterIndexForInsertion(at: point)
            if wordAt(index: charIndex) != nil {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
        super.mouseMoved(with: event)
    }

    override func flagsChanged(with event: NSEvent) {
        if !event.modifierFlags.contains(.command) {
            NSCursor.iBeam.set()
        }
        super.flagsChanged(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    private func wordAt(index: Int) -> String? {
        let str = string as NSString
        guard index >= 0, index < str.length else { return nil }
        let range = str.rangeOfComposedCharacterSequence(at: index)
        guard range.length > 0 else { return nil }

        // Expand to word boundary (identifier chars)
        var start = index
        while start > 0 {
            let c = str.character(at: start - 1)
            guard let scalar = Unicode.Scalar(c),
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar) else { break }
            start -= 1
        }
        var end = index
        while end < str.length {
            let c = str.character(at: end)
            guard let scalar = Unicode.Scalar(c),
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).contains(scalar) else { break }
            end += 1
        }
        guard end > start else { return nil }
        let word = str.substring(with: NSRange(location: start, length: end - start))
        return word.isEmpty ? nil : word
    }
}

// MARK: - Highlighted Code View (NSTextView + tree-sitter)

struct HighlightedCodeView: NSViewRepresentable {
    @Binding var content: String
    let filePath: String
    @Binding var isModified: Bool
    let projectRoot: String
    let onSave: () -> Void
    let onNavigate: (IndexEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ClickableTextView.makeScrollableTextView()
        let textView = scrollView.documentView as! ClickableTextView

        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = defaultTextColor
        textView.backgroundColor = bgColor
        textView.insertionPointColor = .white
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.usesFindBar = true
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.delegate = context.coordinator

        textView.onSymbolClick = { [weak textView] symbolName in
            guard textView != nil else { return }
            context.coordinator.lookupSymbol(symbolName)
        }

        // Line numbers
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler

        scrollView.drawsBackground = true
        scrollView.backgroundColor = bgColor
        scrollView.scrollerStyle = .overlay

        context.coordinator.textView = textView
        applyHighlighting(to: textView)

        // Listen for scroll-to-line notifications
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.scrollToLine(_:)),
            name: .codeEditorScrollToLine,
            object: nil
        )

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ClickableTextView else { return }
        // Only update if content changed externally (not from editing)
        if !context.coordinator.isEditing && textView.string != content {
            context.coordinator.suppressTextDidChange = true
            applyHighlighting(to: textView)
            context.coordinator.suppressTextDidChange = false
        }
    }

    private func applyHighlighting(to textView: NSTextView) {
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

        guard let queryString = HighlightQueries.query(for: languageId),
              let queryData = queryString.data(using: .utf8) else {
            return result
        }

        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch { return result }
        guard let tree = parser.parse(content) else { return result }
        guard let rootNode = tree.rootNode else { return result }

        // Try the full query first; if it fails (unsupported predicates), strip predicates and retry
        let query: Query
        if let q = try? Query(language: tsLanguage, data: queryData) {
            query = q
        } else {
            let stripped = queryString
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("(#") }
                .joined(separator: "\n")
            guard let strippedData = stripped.data(using: .utf8),
                  let q = try? Query(language: tsLanguage, data: strippedData) else {
                return result
            }
            query = q
        }

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

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: HighlightedCodeView
        weak var textView: ClickableTextView?
        var isEditing = false
        var suppressTextDidChange = false
        private var rehighlightTask: DispatchWorkItem?

        init(parent: HighlightedCodeView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !suppressTextDidChange else { return }
            guard let textView = notification.object as? NSTextView else { return }

            isEditing = true
            parent.content = textView.string
            parent.isModified = true

            // Debounced re-highlighting (300ms)
            rehighlightTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                DispatchQueue.main.async {
                    self?.applyRehighlight()
                }
            }
            rehighlightTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: task)
        }

        private func applyRehighlight() {
            guard let textView = textView else { return }
            let selectedRanges = textView.selectedRanges
            let scrollPos = textView.enclosingScrollView?.contentView.bounds.origin

            suppressTextDidChange = true
            let highlighted = parent.buildHighlightedString()
            textView.textStorage?.setAttributedString(highlighted)

            // Restore selection and scroll position
            textView.selectedRanges = selectedRanges
            if let scrollPos = scrollPos {
                textView.enclosingScrollView?.contentView.scroll(to: scrollPos)
            }
            suppressTextDidChange = false
            isEditing = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            // Cmd+S save
            if commandSelector == NSSelectorFromString("saveDocument:") {
                parent.onSave()
                return true
            }
            return false
        }

        func lookupSymbol(_ name: String) {
            guard let index = IndexStore.load(projectRoot: parent.projectRoot) else { return }
            guard let entry = index.find(name: name) else { return }
            parent.onNavigate(entry)
        }

        @objc func scrollToLine(_ notification: Notification) {
            guard let line = notification.userInfo?["line"] as? Int,
                  let textView = textView else { return }
            let string = textView.string as NSString
            var currentLine = 1
            var charIndex = 0
            while currentLine < line && charIndex < string.length {
                let lineRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
                charIndex = NSMaxRange(lineRange)
                currentLine += 1
            }
            let targetRange = string.lineRange(for: NSRange(location: charIndex, length: 0))
            textView.scrollRangeToVisible(targetRange)
            textView.setSelectedRange(targetRange)
            textView.showFindIndicator(for: targetRange)
        }
    }
}

// MARK: - Scrollable text view factory override

extension ClickableTextView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    /// Factory to create a scrollable ClickableTextView (mirrors NSTextView.scrollableTextView()).
    static func makeScrollableTextView() -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(size: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = ClickableTextView(frame: NSRect(origin: .zero, size: contentSize), textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        return scrollView
    }
}

// MARK: - Colors

private let bgColor = NSColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1.0)
private let defaultTextColor = NSColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1.0)
private let gutterBgColor = NSColor(red: 0.065, green: 0.065, blue: 0.065, alpha: 1.0)
private let gutterTextColor = NSColor(red: 0.361, green: 0.388, blue: 0.424, alpha: 1.0)

/// One Dark inspired palette. Looks up by exact name, then falls back to parent scope.
private func captureColor(for name: String) -> NSColor {
    if let color = captureColors[name] { return color }
    // Fall back to parent scope: "keyword.return" → "keyword"
    if let dot = name.lastIndex(of: ".") {
        let parent = String(name[name.startIndex..<dot])
        if let color = captureColors[parent] { return color }
    }
    return defaultTextColor
}

private let purple    = NSColor(red: 0.776, green: 0.471, blue: 0.867, alpha: 1.0)
private let green     = NSColor(red: 0.596, green: 0.765, blue: 0.475, alpha: 1.0)
private let gray      = NSColor(red: 0.361, green: 0.388, blue: 0.424, alpha: 1.0)
private let blue      = NSColor(red: 0.380, green: 0.686, blue: 0.878, alpha: 1.0)
private let yellow    = NSColor(red: 0.898, green: 0.753, blue: 0.424, alpha: 1.0)
private let orange    = NSColor(red: 0.820, green: 0.604, blue: 0.400, alpha: 1.0)
private let red       = NSColor(red: 0.878, green: 0.376, blue: 0.290, alpha: 1.0)
private let lightGray = NSColor(red: 0.671, green: 0.698, blue: 0.745, alpha: 1.0)

private let captureColors: [String: NSColor] = [
    "keyword": purple,
    "keyword.return": purple,
    "keyword.function": purple,
    "keyword.import": purple,
    "keyword.operator": purple,
    "keyword.exception": purple,
    "keyword.debug": purple,
    "string": green,
    "string.special": green,
    "string.escape": orange,
    "comment": gray,
    "comment.doc": gray,
    "function": blue,
    "function.builtin": blue,
    "function.call": blue,
    "function.method": blue,
    "method": blue,
    "type": yellow,
    "type.builtin": yellow,
    "type.definition": yellow,
    "number": orange,
    "float": orange,
    "variable": red,
    "variable.builtin": orange,
    "variable.parameter": red,
    "constant": orange,
    "constant.builtin": orange,
    "operator": lightGray,
    "property": red,
    "punctuation": lightGray,
    "punctuation.bracket": lightGray,
    "punctuation.delimiter": lightGray,
    "punctuation.special": lightGray,
    "include": purple,
    "import": purple,
    "boolean": orange,
    "constructor": yellow,
    "tag": red,
    "attribute": purple,
    "module": yellow,
    "namespace": yellow,
    "conditional": purple,
    "repeat": purple,
    "exception": purple,
    "label": blue,
    "parameter": red,
    "field": red,
    "character": green,
    "character.special": orange,
    "storageclass": purple,
    "define": purple,
    "preproc": purple,
]

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
