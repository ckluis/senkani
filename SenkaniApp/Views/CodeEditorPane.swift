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

    // Diff state
    @State private var originalContent: String = ""
    @State private var showDiff: Bool = false
    @State private var hunks: [DiffHunk] = []

    // Cached intelligence data (refreshed on file open, not every render)
    @State private var cachedDepCount: Int?
    @State private var cachedLastAccess: String?
    @State private var cachedSymbols: [IndexEntry] = []
    @State private var cachedDepGraph: DependencyGraph?

    var body: some View {
        HSplitView {
            // Left: file tree
            FileTreeView(
                rootPath: pane.workingDirectory,
                selectedFile: $filePath,
                onFileSelect: { path in
                    filePath = path
                    openFile()
                }
            )
            .frame(minWidth: 150, idealWidth: 200, maxWidth: 300)

            // Right: editor
            VStack(spacing: 0) {
                fileBar
                Divider()
                editorContent
            }
            .frame(minWidth: 300)
        }
    }

    // MARK: - File bar

    private var fileBar: some View {
        HStack(spacing: 6) {
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

            // Reload from disk
            Button(action: { reloadAndDiff() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SenkaniTheme.textTertiary)
            .help("Reload file from disk and show changes")

            // Diff toggle
            Button(action: { toggleDiff() }) {
                HStack(spacing: 3) {
                    Image(systemName: showDiff ? "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
                        .font(.system(size: 11))
                    if !hunks.isEmpty {
                        Text("\(hunks.count)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                    }
                }
                .foregroundStyle(showDiff ? SenkaniTheme.accentDiffViewer : SenkaniTheme.textTertiary)
            }
            .buttonStyle(.plain)
            .help(showDiff ? "Hide diff" : "Show changes since file was opened")
            .disabled(fileContent == originalContent && !showDiff)

            Spacer()

            if !filePath.isEmpty && !fileContent.isEmpty {
                fileIntelligenceBadges
            }

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
    }

    // MARK: - Editor content

    @ViewBuilder
    private var editorContent: some View {
        if fileContent.isEmpty && !isModified {
            VStack {
                Spacer()
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 32))
                    .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                Text("Select a file from the tree or enter a path")
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
                onNavigate: { entry in navigateToSymbol(entry) }
            )
        }
    }

    // MARK: - File intelligence badges

    @ViewBuilder
    private var fileIntelligenceBadges: some View {
        HStack(spacing: 10) {
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
        originalContent = content
        isModified = false
        showDiff = false
        hunks = []
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
            // Save failed silently
        }
    }

    private func navigateToSymbol(_ entry: IndexEntry) {
        let absPath = entry.file.hasPrefix("/")
            ? entry.file
            : (pane.workingDirectory + "/" + entry.file)
        filePath = absPath
        guard let content = try? String(contentsOfFile: absPath, encoding: .utf8) else { return }
        fileContent = content
        originalContent = content
        isModified = false
        showDiff = false
        hunks = []
        pane.previewFilePath = absPath
        refreshIntelligence()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(
                name: .codeEditorScrollToLine,
                object: nil,
                userInfo: ["line": entry.startLine]
            )
        }
    }

    // MARK: - Diff operations

    private func toggleDiff() {
        if showDiff {
            showDiff = false
            hunks = []
        } else {
            hunks = DiffEngine.computeHunks(original: originalContent, modified: fileContent)
            showDiff = true
        }
    }

    private func reloadAndDiff() {
        let path = filePath.hasPrefix("/") ? filePath : (pane.workingDirectory + "/" + filePath)
        guard let diskContent = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        if diskContent != fileContent {
            fileContent = diskContent
            hunks = DiffEngine.computeHunks(original: originalContent, modified: fileContent)
            showDiff = !hunks.isEmpty
            isModified = false
        }
    }

    private func acceptHunk(at index: Int) {
        guard index < hunks.count else { return }
        hunks[index].resolution = true
        checkAllResolved()
    }

    private func rejectHunk(at index: Int) {
        guard index < hunks.count else { return }
        hunks[index].resolution = false
        checkAllResolved()
    }

    private func checkAllResolved() {
        if hunks.allSatisfy(\.isResolved) {
            fileContent = DiffEngine.applyResolutions(
                original: originalContent,
                modified: fileContent,
                hunks: hunks
            )
            originalContent = fileContent
            showDiff = false
            hunks = []
            isModified = true
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

            let moduleName = ((currentPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let dependents = graph.dependents(of: moduleName)
            let depCount = dependents.isEmpty ? nil : dependents.count

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

// MARK: - Pure SwiftUI Highlighted Code View

struct HighlightedCodeView: View {
    @Binding var content: String
    let filePath: String
    @Binding var isModified: Bool
    let projectRoot: String
    let showTokenCosts: Bool
    let symbolEntries: [IndexEntry]
    let onNavigate: (IndexEntry) -> Void

    @State private var attributedContent: AttributedString = AttributedString()
    @State private var scrollTarget: Int?

    private let lineHeight: CGFloat = 18

    private var lineCount: Int {
        let display = content.count > 50_000 ? String(content.prefix(50_000)) : content
        return max(display.components(separatedBy: "\n").count, 1)
    }

    private static let bgColor = Color(red: 0.055, green: 0.055, blue: 0.055)
    private static let gutterBg = Color(red: 0.065, green: 0.065, blue: 0.065)
    private static let gutterText = Color(red: 0.36, green: 0.39, blue: 0.42)
    private static let defaultText = Color(red: 0.88, green: 0.88, blue: 0.88)
    private static let tokenCostColor = Color(red: 0.25, green: 0.69, blue: 0.41)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                HStack(alignment: .top, spacing: 0) {
                    // Line number gutter
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(1...lineCount, id: \.self) { num in
                            Text("\(num)")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Self.gutterText)
                                .frame(height: lineHeight, alignment: .trailing)
                                .id(num)
                        }
                    }
                    .frame(width: showTokenCosts ? 72 : 40, alignment: .trailing)
                    .padding(.trailing, 8)
                    .background(Self.gutterBg)

                    // Separator
                    Rectangle()
                        .fill(Color(red: 0.15, green: 0.15, blue: 0.15))
                        .frame(width: 0.5)

                    // Code content — single attributed Text
                    Text(attributedContent)
                        .font(.system(size: 13, design: .monospaced))
                        .lineSpacing(0)
                        .textSelection(.enabled)
                        .tint(Color(red: 0.2, green: 0.3, blue: 0.5))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.leading, 8)
                        .padding(.top, 8)
                }
                .padding(.top, 0)
            }
            .background(Self.bgColor)
            .accentColor(Color(red: 0.2, green: 0.3, blue: 0.5))
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation {
                        proxy.scrollTo(target, anchor: .center)
                    }
                    scrollTarget = nil
                }
            }
        }
        .onAppear { buildAttributedContent() }
        .onChange(of: content) { _, _ in buildAttributedContent() }
        .onReceive(NotificationCenter.default.publisher(for: .codeEditorScrollToLine)) { notification in
            if let line = notification.userInfo?["line"] as? Int {
                scrollTarget = line
            }
        }
    }

    // MARK: - Build single AttributedString for the whole file

    private func buildAttributedContent() {
        print("[HL] buildAttributedContent: \(content.count) chars, filePath=\(filePath)")

        // Cap at 50,000 characters to prevent SwiftUI layer size crash
        // (macOS rejects backing layers taller than ~16K points)
        var displayContent = content
        if displayContent.count > 50_000 {
            let truncIndex = displayContent.index(displayContent.startIndex, offsetBy: 50_000)
            displayContent = String(displayContent[..<truncIndex])
            let totalLines = content.components(separatedBy: "\n").count
            let shownLines = displayContent.components(separatedBy: "\n").count
            displayContent += "\n\n// [\(shownLines) of \(totalLines) lines shown — file too large for inline display]"
            print("[HL] Truncated from \(content.count) to 50000 chars")
        }

        // Start with default-styled display content
        var result = AttributedString(displayContent)
        result.foregroundColor = Self.defaultText
        result.font = .system(size: 13, design: .monospaced)

        // Apply syntax highlighting
        let captures = getCaptures(for: displayContent)
        var appliedCount = 0

        for capture in captures {
            let nsRange = NSRange(location: capture.location, length: capture.length)

            // Convert NSRange (UTF-16) to String.Index
            let utf16 = displayContent.utf16
            let utf16Start = utf16.index(utf16.startIndex, offsetBy: nsRange.location, limitedBy: utf16.endIndex)
            guard let utf16Start else { continue }
            let utf16End = utf16.index(utf16Start, offsetBy: nsRange.length, limitedBy: utf16.endIndex)
            guard let utf16End else { continue }

            // Convert UTF-16 indices to String character indices
            guard let charStart = utf16Start.samePosition(in: displayContent),
                  let charEnd = utf16End.samePosition(in: displayContent) else { continue }

            // Convert String.Index to AttributedString.Index
            let attrStart = AttributedString.Index(charStart, within: result)
            let attrEnd = AttributedString.Index(charEnd, within: result)
            guard let attrStart, let attrEnd, attrStart < attrEnd else { continue }

            result[attrStart..<attrEnd].foregroundColor = capture.color
            appliedCount += 1
        }

        print("[HL] Applied \(appliedCount) color ranges")
        attributedContent = result
    }

    // MARK: - Tree-sitter captures

    private struct CaptureInfo {
        let location: Int  // UTF-16 offset in full file
        let length: Int    // UTF-16 length
        let color: Color
    }

    private func getCaptures(for sourceContent: String) -> [CaptureInfo] {
        let ext = (filePath as NSString).pathExtension.lowercased()

        guard let languageId = FileWalker.languageMap[ext] else {
            print("[HL] No language mapping for extension: '\(ext)'")
            return []
        }

        guard let tsLanguage = TreeSitterBackend.language(for: languageId) else {
            print("[HL] TreeSitterBackend has no language for: '\(languageId)'")
            return []
        }

        guard let queryString = HighlightQueries.query(for: languageId) else {
            print("[HL] No highlight query for: '\(languageId)'")
            return []
        }

        guard let queryData = queryString.data(using: .utf8) else {
            print("[HL] Could not encode query string")
            return []
        }

        let parser = Parser()
        do { try parser.setLanguage(tsLanguage) } catch {
            print("[HL] Failed to set language: \(error)")
            return []
        }

        guard let tree = parser.parse(sourceContent) else {
            print("[HL] Failed to parse content (\(sourceContent.count) chars)")
            return []
        }

        guard let rootNode = tree.rootNode else {
            print("[HL] No root node in parse tree")
            return []
        }

        let query: Query?
        if let q = try? Query(language: tsLanguage, data: queryData) {
            query = q
            print("[HL] Query compiled OK for \(languageId)")
        } else {
            print("[HL] Query failed, trying stripped version for \(languageId)")
            let stripped = queryString
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("(#") }
                .joined(separator: "\n")
            query = try? Query(language: tsLanguage, data: stripped.data(using: .utf8)!)
            print("[HL] Stripped query: \(query != nil ? "OK" : "FAILED")")
        }

        guard let query else {
            print("[HL] No query available")
            return []
        }

        let cursor = query.execute(node: rootNode, in: tree)
        var captures: [CaptureInfo] = []

        for match in cursor {
            for capture in match.captures {
                guard let name = capture.name else { continue }
                let range = capture.range
                captures.append(CaptureInfo(
                    location: range.location,
                    length: range.length,
                    color: swiftUIColor(for: name)
                ))
            }
        }

        print("[HL] Extracted \(captures.count) captures for \(languageId)")
        return captures
    }

    // MARK: - Color mapping

    private func swiftUIColor(for captureName: String) -> Color {
        if let color = Self.captureColorMap[captureName] { return color }
        if let dot = captureName.lastIndex(of: ".") {
            let parent = String(captureName[captureName.startIndex..<dot])
            if let color = Self.captureColorMap[parent] { return color }
        }
        return Self.defaultText
    }

    private static let captureColorMap: [String: Color] = [
        "keyword":      Color(red: 0.776, green: 0.471, blue: 0.867),
        "keyword.return": Color(red: 0.776, green: 0.471, blue: 0.867),
        "keyword.function": Color(red: 0.776, green: 0.471, blue: 0.867),
        "keyword.import": Color(red: 0.776, green: 0.471, blue: 0.867),
        "keyword.operator": Color(red: 0.776, green: 0.471, blue: 0.867),
        "string":       Color(red: 0.596, green: 0.765, blue: 0.475),
        "string.special": Color(red: 0.596, green: 0.765, blue: 0.475),
        "string.escape": Color(red: 0.820, green: 0.604, blue: 0.400),
        "comment":      Color(red: 0.361, green: 0.388, blue: 0.424),
        "comment.doc":  Color(red: 0.361, green: 0.388, blue: 0.424),
        "function":     Color(red: 0.380, green: 0.686, blue: 0.878),
        "function.builtin": Color(red: 0.380, green: 0.686, blue: 0.878),
        "function.call": Color(red: 0.380, green: 0.686, blue: 0.878),
        "function.method": Color(red: 0.380, green: 0.686, blue: 0.878),
        "method":       Color(red: 0.380, green: 0.686, blue: 0.878),
        "type":         Color(red: 0.898, green: 0.753, blue: 0.424),
        "type.builtin": Color(red: 0.898, green: 0.753, blue: 0.424),
        "type.definition": Color(red: 0.898, green: 0.753, blue: 0.424),
        "number":       Color(red: 0.820, green: 0.604, blue: 0.400),
        "float":        Color(red: 0.820, green: 0.604, blue: 0.400),
        "variable":     Color(red: 0.878, green: 0.376, blue: 0.290),
        "variable.builtin": Color(red: 0.820, green: 0.604, blue: 0.400),
        "variable.parameter": Color(red: 0.878, green: 0.376, blue: 0.290),
        "constant":     Color(red: 0.820, green: 0.604, blue: 0.400),
        "constant.builtin": Color(red: 0.820, green: 0.604, blue: 0.400),
        "operator":     Color(red: 0.671, green: 0.698, blue: 0.745),
        "property":     Color(red: 0.878, green: 0.376, blue: 0.290),
        "punctuation":  Color(red: 0.671, green: 0.698, blue: 0.745),
        "punctuation.bracket": Color(red: 0.671, green: 0.698, blue: 0.745),
        "punctuation.delimiter": Color(red: 0.671, green: 0.698, blue: 0.745),
        "boolean":      Color(red: 0.820, green: 0.604, blue: 0.400),
        "constructor":  Color(red: 0.898, green: 0.753, blue: 0.424),
        "tag":          Color(red: 0.878, green: 0.376, blue: 0.290),
        "attribute":    Color(red: 0.776, green: 0.471, blue: 0.867),
        "module":       Color(red: 0.898, green: 0.753, blue: 0.424),
        "namespace":    Color(red: 0.898, green: 0.753, blue: 0.424),
        "include":      Color(red: 0.776, green: 0.471, blue: 0.867),
        "import":       Color(red: 0.776, green: 0.471, blue: 0.867),
        "conditional":  Color(red: 0.776, green: 0.471, blue: 0.867),
        "repeat":       Color(red: 0.776, green: 0.471, blue: 0.867),
        "exception":    Color(red: 0.776, green: 0.471, blue: 0.867),
        "label":        Color(red: 0.380, green: 0.686, blue: 0.878),
        "parameter":    Color(red: 0.878, green: 0.376, blue: 0.290),
        "field":        Color(red: 0.878, green: 0.376, blue: 0.290),
        "character":    Color(red: 0.596, green: 0.765, blue: 0.475),
        "preproc":      Color(red: 0.776, green: 0.471, blue: 0.867),
        "define":       Color(red: 0.776, green: 0.471, blue: 0.867),
        "storageclass": Color(red: 0.776, green: 0.471, blue: 0.867),
    ]
}
