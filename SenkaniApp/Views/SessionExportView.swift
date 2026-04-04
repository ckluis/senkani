import SwiftUI
import UniformTypeIdentifiers

/// Toolbar menu button for session export actions.
struct SessionExportMenuButton: View {
    let workspace: WorkspaceModel
    private let sessionStore = SessionStore.shared

    var body: some View {
        Menu {
            Button {
                exportAsJSON()
            } label: {
                Label("Export as JSON...", systemImage: "doc.text")
            }

            Button {
                exportAsReport()
            } label: {
                Label("Export as Report...", systemImage: "doc.richtext")
            }

            Divider()

            Button {
                sessionStore.saveSession(workspace: workspace)
            } label: {
                Label("Save Session Snapshot", systemImage: "square.and.arrow.down")
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("Export session data")
    }

    private func exportAsJSON() {
        guard let data = sessionStore.exportJSON(workspace: workspace) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "senkani-session.json"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }

    private func exportAsReport() {
        let report = sessionStore.exportReport(workspace: workspace)
        guard let data = report.data(using: .utf8) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.plainText]
        panel.nameFieldStringValue = "senkani-report.md"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                try? data.write(to: url)
            }
        }
    }
}
