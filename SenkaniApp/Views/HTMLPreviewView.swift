import SwiftUI
import WebKit

/// Renders a raw HTML file in a WKWebView with live auto-reload.
struct HTMLPreviewView: View {
    @Bindable var pane: PaneModel

    @State private var filePath: String = ""
    @State private var isDropTargeted = false
    @State private var pathError: String?

    var body: some View {
        if pane.previewFilePath.isEmpty {
            filePickerPrompt
        } else {
            WebViewRepresentable(filePath: pane.previewFilePath, mode: .html)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var filePickerPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: isDropTargeted ? "arrow.down.doc.fill" : "globe")
                .font(.system(size: 40))
                .foregroundStyle(isDropTargeted ? .blue : .secondary)
                .animation(.easeInOut(duration: 0.15), value: isDropTargeted)

            Text("HTML Preview")
                .font(.headline)
            Text("Choose an .html file to preview, or drag and drop")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("File path", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
                    .onSubmit { applyPath() }

                Button("Browse...") {
                    pickFile()
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

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.html]
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
