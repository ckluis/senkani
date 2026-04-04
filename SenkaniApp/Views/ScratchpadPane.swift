import SwiftUI

/// Quick scratchpad for notes, snippets, and scratch thinking during sessions.
/// Auto-saves to ~/.senkani/scratchpads/{pane-id}.md
struct ScratchpadPane: View {
    @Bindable var pane: PaneModel
    @State private var text: String = ""
    @State private var wordCount: Int = 0
    @State private var lastSaved: Date?
    @FocusState private var isFocused: Bool

    private var savePath: String {
        NSHomeDirectory() + "/.senkani/scratchpads/\(pane.id.uuidString).md"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Text("\(wordCount) words")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Spacer()

                if let saved = lastSaved {
                    Text("saved \(saved.formatted(.relative(presentation: .numeric)))")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }

                Button {
                    copyAll()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SenkaniTheme.textTertiary)
                .help("Copy all to clipboard")

                Button {
                    clearAll()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SenkaniTheme.textTertiary)
                .help("Clear scratchpad")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneShell)

            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            // Editor
            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .focused($isFocused)
                .padding(8)
                .background(SenkaniTheme.paneBody)
                .onChange(of: text) { _, newValue in
                    wordCount = newValue.split(separator: " ").count
                    autoSave()
                }
        }
        .onAppear { loadFromDisk() }
    }

    private func loadFromDisk() {
        if let data = FileManager.default.contents(atPath: savePath),
           let content = String(data: data, encoding: .utf8) {
            text = content
            wordCount = content.split(separator: " ").count
        }
    }

    private func autoSave() {
        let dir = (savePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? text.write(toFile: savePath, atomically: true, encoding: .utf8)
        lastSaved = Date()
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func clearAll() {
        text = ""
        autoSave()
    }
}
