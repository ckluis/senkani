import SwiftUI
import WebKit

/// Renders a raw HTML file in a WKWebView with live auto-reload.
struct HTMLPreviewView: View {
    @Bindable var pane: PaneModel

    @State private var filePath: String = ""

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
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("HTML Preview")
                .font(.headline)
            Text("Choose an .html file to preview")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("File path", text: $filePath)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 400)
                    .onSubmit { applyPath() }

                Button("Browse...") {
                    pickFile()
                }
            }
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func applyPath() {
        let expanded = (filePath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return }
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
