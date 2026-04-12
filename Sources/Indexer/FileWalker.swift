import Foundation

/// Walks a project directory and returns source files grouped by language.
public enum FileWalker {
    /// Directories to always skip.
    public static let skipDirs: Set<String> = [
        ".git", ".build", ".senkani", "node_modules", "__pycache__",
        ".swiftpm", "build", "DerivedData", ".cache", "vendor",
        "Pods", ".gradle", "target", "dist", ".next",
    ]

    /// File extension to language mapping.
    public static let languageMap: [String: String] = [
        "swift": "swift",
        "ts": "typescript", "tsx": "tsx",
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
        "py": "python",
        "go": "go",
        "rs": "rust",
        "java": "java",
        "kt": "kotlin", "kts": "kotlin",
        "c": "c", "h": "c",
        "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
        "cs": "csharp",
        "rb": "ruby",
        "php": "php",
        "zig": "zig",
        "lua": "lua",
        "sh": "bash", "bash": "bash", "zsh": "bash",
        "scala": "scala", "sc": "scala",
        "ex": "elixir", "exs": "elixir",
        "hs": "haskell", "lhs": "haskell",
    ]

    public struct WalkResult: Sendable {
        public let files: [String]                       // all source files (relative paths)
        public let byLanguage: [String: [String]]        // language → [relative paths]
    }

    /// Walk the project and return source files.
    public static func walk(projectRoot: String) -> WalkResult {
        let fm = FileManager.default
        var files: [String] = []
        var byLanguage: [String: [String]] = [:]

        // Load .gitignore patterns (simple subset)
        let gitignorePatterns = loadGitignore(at: projectRoot)

        let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: projectRoot),
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        while let url = enumerator?.nextObject() as? URL {
            let relativePath = url.path.replacingOccurrences(of: projectRoot + "/", with: "")

            // Skip known directories
            if let dirName = relativePath.split(separator: "/").first.map(String.init),
               skipDirs.contains(dirName) {
                enumerator?.skipDescendants()
                continue
            }

            // Skip directories in skipDirs at any level
            let components = relativePath.split(separator: "/").map(String.init)
            if components.dropLast().contains(where: { skipDirs.contains($0) }) {
                continue
            }

            // Skip gitignored files (simple check)
            if isGitignored(relativePath, patterns: gitignorePatterns) {
                continue
            }

            // Only process regular files
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard let language = languageMap[ext] else { continue }

            files.append(relativePath)
            byLanguage[language, default: []].append(relativePath)
        }

        return WalkResult(files: files, byLanguage: byLanguage)
    }

    private static func loadGitignore(at root: String) -> [String] {
        let path = root + "/.gitignore"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return content.split(separator: "\n")
            .map(String.init)
            .filter { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func isGitignored(_ path: String, patterns: [String]) -> Bool {
        for pattern in patterns {
            let clean = pattern.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "")
            if path.contains(clean) { return true }
        }
        return false
    }
}
