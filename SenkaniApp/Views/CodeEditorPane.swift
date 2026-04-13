import SwiftUI
import AppKit
import SwiftTreeSitter
import Indexer
import Core

struct CodeEditorPane: View {
    @Bindable var pane: PaneModel
    @State private var fileContent: String = ""
    @State private var filePath: String = ""
    @State private var isModified: Bool = false
    @State private var showTokenCosts: Bool = false

    // Cached intelligence data (refreshed on file open, not every render)
    @State private var cachedDepCount: Int?
    @State private var cachedLastAccess: String?
    @State private var cachedSymbols: [IndexEntry] = []
    @State private var cachedDepGraph: DependencyGraph?

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

                Spacer()

                // File intelligence badges (only when a file is loaded)
                if !filePath.isEmpty && !fileContent.isEmpty {
                    fileIntelligenceBadges
                }

                // Gutter token cost toggle
                Button(action: { showTokenCosts.toggle() }) {
                    Image(systemName: showTokenCosts ? "dollarsign.circle.fill" : "dollarsign.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(showTokenCosts ? SenkaniTheme.savingsGreen : SenkaniTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(showTokenCosts ? "Hide token cost annotations" : "Show token cost per function")
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
                    showTokenCosts: showTokenCosts,
                    symbolEntries: cachedSymbols,
                    depGraph: cachedDepGraph,
                    onSave: { saveFile() },
                    onNavigate: { entry in navigateToSymbol(entry) }
                )
            }
        }
    }

    // MARK: - File intelligence badges

    @ViewBuilder
    private var fileIntelligenceBadges: some View {
        HStack(spacing: 10) {
            // Token cost estimate for the whole file
            let tokens = fileContent.utf8.count / 4
            HStack(spacing: 3) {
                Image(systemName: "number")
                    .font(.system(size: 8))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Text(formatTokenCount(tokens))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .help("Estimated token cost to read this file: ~\(tokens) tokens")

            // Dependency count
            if let depCount = cachedDepCount {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Text("\(depCount)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .help("\(depCount) file(s) import this module")
            }

            // Last AI access time
            if let lastAccess = cachedLastAccess {
                HStack(spacing: 3) {
                    Circle()
                        .fill(SenkaniTheme.savingsGreen.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(lastAccess)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .help("Last accessed by senkani MCP tools")
            }
        }
    }

    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens >= 1000 { return String(format: "%.1fKt", Double(tokens) / 1000) }
        return "~\(tokens)t"
    }

    // MARK: - File operations

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
        refreshIntelligence()
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
        refreshIntelligence()

        // Post notification to scroll to the target line
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .codeEditorScrollToLine,
                object: nil,
                userInfo: ["line": entry.startLine]
            )
        }
    }

    // MARK: - Async intelligence refresh

    private func refreshIntelligence() {
        let projectRoot = pane.workingDirectory
        let currentPath = filePath

        Task.detached {
            let graph = IndexEngine.buildDependencyGraph(projectRoot: projectRoot)
            let index = IndexStore.load(projectRoot: projectRoot)

            let relativePath = currentPath.hasPrefix(projectRoot + "/")
                ? String(currentPath.dropFirst(projectRoot.count + 1))
                : (currentPath as NSString).lastPathComponent

            let symbols = index?.search(file: relativePath).sorted { $0.startLine < $1.startLine } ?? []

            // Module name for dependency lookup — use the file's basename without extension
            let moduleName = ((currentPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let dependents = graph.dependents(of: moduleName)
            let depCount = dependents.isEmpty ? nil : dependents.count

            // Last AI access
            let db = SessionDatabase.shared
            let lastRead = db.lastReadTimestamp(filePath: currentPath, projectRoot: projectRoot)
            var accessLabel: String?
            if let lastRead = lastRead {
                let age = Date().timeIntervalSince(lastRead)
                if age < 60 { accessLabel = "\(Int(age))s ago" }
                else if age < 3600 { accessLabel = "\(Int(age / 60))m ago" }
                else if age < 86400 { accessLabel = "\(Int(age / 3600))h ago" }
            }

            await MainActor.run {
                cachedDepGraph = graph
                cachedSymbols = symbols
                cachedDepCount = depCount
                cachedLastAccess = accessLabel
            }
        }
    }
}

// MARK: - Notification for scroll-to-line

extension Notification.Name {
    static let codeEditorScrollToLine = Notification.Name("codeEditorScrollToLine")
}

// MARK: - Clickable Text View (Cmd+click + import tooltips)

final class ClickableTextView: NSTextView {
    var onSymbolClick: ((String) -> Void)?
    var depGraph: DependencyGraph?

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

    // MARK: - Import line tooltip

    func importTooltip(at point: NSPoint) -> String? {
        let charIndex = characterIndexForInsertion(at: point)
        let nsString = string as NSString
        guard charIndex >= 0, charIndex < nsString.length else { return nil }

        let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
        let line = nsString.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)

        let importPatterns = ["import ", "from ", "require(", "use ", "#include ", "using "]
        guard importPatterns.contains(where: { line.hasPrefix($0) || line.contains($0) }) else {
            return nil
        }

        let words = line.components(separatedBy: .whitespaces)
            .flatMap { $0.components(separatedBy: CharacterSet(charactersIn: "\"'();{}<>")) }
            .filter { !$0.isEmpty && !["import", "from", "use", "#include", "using", "require", "@testable"].contains($0) }
        guard let moduleName = words.last, !moduleName.isEmpty else { return nil }

        guard let graph = depGraph else { return nil }
        let dependents = graph.dependents(of: moduleName)
        guard !dependents.isEmpty else { return nil }

        let preview = dependents.prefix(5).joined(separator: "\n  ")
        let more = dependents.count > 5 ? "\n  ... and \(dependents.count - 5) more" : ""
        return "\(dependents.count) file(s) import \(moduleName):\n  \(preview)\(more)"
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Show import tooltip
        if let tooltip = importTooltip(at: point) {
            self.toolTip = tooltip
        } else {
            self.toolTip = nil
        }

        // Cmd+hover cursor
        if event.modifierFlags.contains(.command) {
            let charIndex = characterIndexForInsertion(at: point)
            if wordAt(index: charIndex) != nil {
                NSCursor.pointingHand.set()
                return
            }
        }
        NSCursor.iBeam.set()
    }

    // MARK: - Word extraction

    func wordAt(index: Int) -> String? {
        let str = string as NSString
        guard index >= 0, index < str.length else { return nil }
        let range = str.rangeOfComposedCharacterSequence(at: index)
        guard range.length > 0 else { return nil }

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
    let showTokenCosts: Bool
    let symbolEntries: [IndexEntry]
    let depGraph: DependencyGraph?
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

        textView.depGraph = depGraph

        // Line numbers
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        ruler.showTokenCosts = showTokenCosts
        ruler.symbolEntries = symbolEntries
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

        // Update dependency graph for tooltips
        textView.depGraph = depGraph

        // Update ruler state
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.showTokenCosts = showTokenCosts
            ruler.symbolEntries = symbolEntries
            ruler.ruleThickness = showTokenCosts ? 64 : 40
            ruler.needsDisplay = true
        }

        // Only update text if content changed externally (not from editing)
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
    func buildHighlightedString() -> NSAttributedString {
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

            textView.selectedRanges = selectedRanges
            if let scrollPos = scrollPos {
                textView.enclosingScrollView?.contentView.scroll(to: scrollPos)
            }
            suppressTextDidChange = false
            isEditing = false
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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

// MARK: - Scrollable text view factory

extension ClickableTextView {
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

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
private let tokenCostColor = NSColor(red: 0.286, green: 0.714, blue: 0.529, alpha: 0.5)

private func captureColor(for name: String) -> NSColor {
    if let color = captureColors[name] { return color }
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

// MARK: - Line Number Ruler (with optional token cost annotations)

final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    var showTokenCosts: Bool = false
    var symbolEntries: [IndexEntry] = []

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
        let lineNumAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: gutterTextColor,
        ]

        let costAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: tokenCostColor,
        ]

        // Build a lookup for symbol start lines when token costs are shown
        let symbolStartLines: [Int: IndexEntry]
        if showTokenCosts {
            symbolStartLines = Dictionary(symbolEntries.map { ($0.startLine, $0) }, uniquingKeysWith: { first, _ in first })
        } else {
            symbolStartLines = [:]
        }

        // Line number column width (for positioning)
        let lineNumColumnWidth: CGFloat = showTokenCosts ? 36 : ruleThickness

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

            // Draw line number
            let label = "\(lineNumber)" as NSString
            let labelSize = label.size(withAttributes: lineNumAttrs)
            let drawPoint = NSPoint(
                x: lineNumColumnWidth - labelSize.width - 6,
                y: lineRect.origin.y + (lineRect.height - labelSize.height) / 2
            )
            label.draw(at: drawPoint, withAttributes: lineNumAttrs)

            // Draw token cost annotation if this line starts a symbol
            if showTokenCosts, let symbol = symbolStartLines[lineNumber] {
                let startLine = symbol.startLine
                let endLine = symbol.endLine ?? (startLine + 10)
                let lineCount = max(1, endLine - startLine)
                let estimatedTokens = lineCount * 10

                let costLabel: String
                if estimatedTokens >= 1000 {
                    costLabel = String(format: "%.1fK", Double(estimatedTokens) / 1000)
                } else {
                    costLabel = "~\(estimatedTokens)"
                }

                let costStr = costLabel as NSString
                let costSize = costStr.size(withAttributes: costAttrs)
                let costPoint = NSPoint(
                    x: ruleThickness - costSize.width - 4,
                    y: lineRect.origin.y + (lineRect.height - costSize.height) / 2
                )
                costStr.draw(at: costPoint, withAttributes: costAttrs)
            }

            lineNumber += 1
            charIndex = NSMaxRange(lineRange)
        }
    }
}
