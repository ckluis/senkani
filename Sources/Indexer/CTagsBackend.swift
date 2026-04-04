import Foundation

/// Indexes symbols using Universal ctags (if installed).
public enum CTagsBackend {
    /// Check if Universal ctags is available (not BSD ctags).
    public static func isAvailable() -> Bool {
        let candidates = ["/opt/homebrew/bin/ctags", "/usr/local/bin/ctags"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                // Verify it's Universal ctags
                if let output = runProcess(path, args: ["--version"]) {
                    if output.contains("Universal Ctags") { return true }
                }
            }
        }
        return false
    }

    /// Find the Universal ctags binary path.
    static func findBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/ctags", "/usr/local/bin/ctags"]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path),
               let output = runProcess(path, args: ["--version"]),
               output.contains("Universal Ctags") {
                return path
            }
        }
        return nil
    }

    /// Index a project using Universal ctags.
    public static func index(projectRoot: String, languages: [String]? = nil) -> [IndexEntry] {
        guard let binary = findBinary() else { return [] }

        var args = [
            "--output-format=json",
            "--fields=+neKS",
            "-R",
            "--exclude=.build",
            "--exclude=.git",
            "--exclude=node_modules",
            "--exclude=.senkani",
            "--exclude=DerivedData",
            "--exclude=Pods",
            "--exclude=.swiftpm",
            "--exclude=vendor",
            "--exclude=dist",
            "--exclude=__pycache__",
        ]

        if let langs = languages {
            args.append("--languages=" + langs.joined(separator: ","))
        }

        args.append(projectRoot)

        guard let output = runProcess(binary, args: args) else { return [] }

        var entries: [IndexEntry] = []
        for line in output.split(separator: "\n") {
            guard let entry = parseCtagsLine(String(line), projectRoot: projectRoot) else { continue }
            entries.append(entry)
        }
        return entries
    }

    private static func parseCtagsLine(_ line: String, projectRoot: String) -> IndexEntry? {
        guard let data = line.data(using: .utf8) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        guard let name = json["name"] as? String,
              let kindStr = json["kind"] as? String,
              let path = json["path"] as? String,
              let lineNum = json["line"] as? Int else { return nil }

        let kind = mapCtagsKind(kindStr)
        let relativePath = path.hasPrefix(projectRoot)
            ? String(path.dropFirst(projectRoot.count + 1))
            : path

        let endLine = json["end"] as? Int
        let signature = json["signature"] as? String
            ?? json["pattern"] as? String
        let container = json["scope"] as? String

        return IndexEntry(
            name: name,
            kind: kind,
            file: relativePath,
            startLine: lineNum,
            endLine: endLine,
            signature: signature?.trimmingCharacters(in: CharacterSet(charactersIn: "/^$")),
            container: container,
            engine: "ctags"
        )
    }

    private static func mapCtagsKind(_ kind: String) -> SymbolKind {
        switch kind.lowercased() {
        case "function", "func", "subroutine": return .function
        case "method": return .method
        case "class": return .class
        case "struct", "structure": return .struct
        case "enum", "enumeration": return .enum
        case "protocol", "trait": return .protocol
        case "interface": return .interface
        case "property", "member", "field": return .property
        case "constant": return .constant
        case "variable": return .variable
        case "extension": return .extension
        case "type", "typedef", "typealias": return .type
        default: return .function
        }
    }

    private static func runProcess(_ path: String, args: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
