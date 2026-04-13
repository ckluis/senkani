import SwiftUI

struct FileTreeView: View {
    let rootPath: String
    @Binding var selectedFile: String
    let onFileSelect: (String) -> Void

    @State private var expandedDirs: Set<String> = []
    @State private var entries: [FileEntry] = []

    struct FileEntry: Identifiable {
        let id: String
        let name: String
        let path: String
        let isDirectory: Bool
        let depth: Int
    }

    private static let skipDirs: Set<String> = [
        ".git", ".build", ".senkani", "node_modules", "__pycache__",
        "DerivedData", ".swiftpm", "build", "dist", ".next", "Pods",
    ]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(entries) { entry in
                    fileRow(entry)
                }
            }
            .padding(.vertical, 4)
        }
        .background(Color(nsColor: NSColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1.0)))
        .onAppear { loadDirectory(rootPath, depth: 0) }
    }

    private func fileRow(_ entry: FileEntry) -> some View {
        HStack(spacing: 4) {
            Spacer().frame(width: CGFloat(entry.depth) * 12)

            if entry.isDirectory {
                Image(systemName: expandedDirs.contains(entry.path) ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .frame(width: 10)
            } else {
                Spacer().frame(width: 10)
            }

            Image(systemName: entry.isDirectory ? "folder.fill" : fileIcon(for: entry.name))
                .font(.system(size: 10))
                .foregroundStyle(entry.isDirectory ? SenkaniTheme.accentDiffViewer : SenkaniTheme.textTertiary)

            Text(entry.name)
                .font(.system(size: 11))
                .foregroundStyle(entry.path == selectedFile ? .white : SenkaniTheme.textSecondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(entry.path == selectedFile ? SenkaniTheme.accentAnalytics.opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            if entry.isDirectory {
                toggleDirectory(entry)
            } else {
                onFileSelect(entry.path)
            }
        }
    }

    private func toggleDirectory(_ entry: FileEntry) {
        if expandedDirs.contains(entry.path) {
            expandedDirs.remove(entry.path)
            entries.removeAll { $0.id.hasPrefix(entry.path + "/") }
        } else {
            expandedDirs.insert(entry.path)
            loadDirectory(entry.path, depth: entry.depth + 1, insertAfter: entry.id)
        }
    }

    private func loadDirectory(_ path: String, depth: Int, insertAfter: String? = nil) {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: path) else { return }

        let sorted = contents
            .filter { !$0.hasPrefix(".") || $0 == ".claude" }
            .filter { !Self.skipDirs.contains($0) }
            .sorted { a, b in
                let aIsDir = isDirectory(path + "/" + a)
                let bIsDir = isDirectory(path + "/" + b)
                if aIsDir != bIsDir { return aIsDir }
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }

        let newEntries = sorted.map { name in
            let fullPath = path + "/" + name
            return FileEntry(
                id: fullPath,
                name: name,
                path: fullPath,
                isDirectory: isDirectory(fullPath),
                depth: depth
            )
        }

        if let afterId = insertAfter, let idx = entries.firstIndex(where: { $0.id == afterId }) {
            entries.insert(contentsOf: newEntries, at: idx + 1)
        } else {
            entries = newEntries
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py": return "doc.text"
        case "ts", "tsx", "js", "jsx": return "doc.text"
        case "json": return "curlybraces"
        case "md": return "doc.richtext"
        case "html", "css": return "globe"
        case "sh", "bash", "zsh": return "terminal"
        case "c", "cpp", "h", "hpp": return "doc.text"
        case "rs": return "doc.text"
        case "go": return "doc.text"
        case "rb": return "doc.text"
        case "java", "kt": return "doc.text"
        case "toml", "yaml", "yml": return "gearshape"
        default: return "doc"
        }
    }
}
