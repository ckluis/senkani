import Foundation

/// A symbol kind in the index.
public enum SymbolKind: String, Codable, Sendable, CaseIterable {
    case function, method, `class`, `struct`, `enum`, `protocol`
    case property, constant, variable, `extension`, interface, type
}

/// A single indexed symbol.
public struct IndexEntry: Codable, Sendable {
    public let name: String
    public let kind: SymbolKind
    public let file: String       // relative path from project root
    public let startLine: Int
    public let endLine: Int?
    public let signature: String?
    public let container: String? // enclosing type name
    public let engine: String     // "lsp", "ctags", or "regex"

    public init(name: String, kind: SymbolKind, file: String, startLine: Int,
                endLine: Int? = nil, signature: String? = nil,
                container: String? = nil, engine: String = "regex") {
        self.name = name
        self.kind = kind
        self.file = file
        self.startLine = startLine
        self.endLine = endLine
        self.signature = signature
        self.container = container
        self.engine = engine
    }
}

/// The full project symbol index.
public struct SymbolIndex: Codable, Sendable {
    public var version: Int = 1
    public var engine: String = "regex"
    public var generated: Date = Date()
    public var projectRoot: String = ""
    public var fileHashes: [String: String] = [:]  // relative path → git blob hash
    public var symbols: [IndexEntry] = []

    public init() {}

    // MARK: - Search

    /// Search symbols by name (case-insensitive substring match).
    public func search(name query: String) -> [IndexEntry] {
        let q = query.lowercased()
        return symbols.filter { $0.name.lowercased().contains(q) }
    }

    /// Search with filters.
    public func search(name: String? = nil, kind: SymbolKind? = nil,
                       file: String? = nil, container: String? = nil) -> [IndexEntry] {
        symbols.filter { entry in
            if let n = name, !entry.name.lowercased().contains(n.lowercased()) { return false }
            if let k = kind, entry.kind != k { return false }
            if let f = file, !entry.file.lowercased().contains(f.lowercased()) { return false }
            if let c = container, entry.container?.lowercased().contains(c.lowercased()) != true { return false }
            return true
        }
    }

    /// Find an exact symbol by name (first match).
    public func find(name: String) -> IndexEntry? {
        symbols.first { $0.name == name }
            ?? symbols.first { $0.name.lowercased() == name.lowercased() }
    }

    // MARK: - Mutation

    /// Remove all symbols from a set of files (for incremental re-indexing).
    public mutating func removeSymbols(forFiles files: Set<String>) {
        symbols.removeAll { files.contains($0.file) }
        for f in files { fileHashes.removeValue(forKey: f) }
    }

    /// Add symbols and update file hashes.
    public mutating func addSymbols(_ entries: [IndexEntry], hashes: [String: String]) {
        symbols.append(contentsOf: entries)
        fileHashes.merge(hashes) { _, new in new }
    }

    // MARK: - Explore (tree view)

    /// Group symbols by file, sorted by file path.
    public func groupedByFile(under path: String? = nil) -> [(file: String, symbols: [IndexEntry])] {
        let filtered = path != nil
            ? symbols.filter { $0.file.hasPrefix(path!) }
            : symbols

        let grouped = Dictionary(grouping: filtered) { $0.file }
        return grouped.sorted { $0.key < $1.key }
            .map { (file: $0.key, symbols: $0.value.sorted { $0.startLine < $1.startLine }) }
    }

    // MARK: - Repo Map

    /// Generate a compact repo map for MCP instruction injection.
    /// Shows every file with its top-level symbols and nested members.
    /// Capped at `maxTokens` estimated tokens (~4 chars per token).
    public func repoMap(maxTokens: Int = 2000) -> String {
        let grouped = groupedByFile()
        guard !grouped.isEmpty else { return "" }

        let maxChars = maxTokens * 4
        var lines: [String] = []
        let projectName = projectRoot.split(separator: "/").last.map(String.init) ?? "unknown"
        lines.append("Project: \(projectName) (\(grouped.count) files, \(symbols.count) symbols)")
        lines.append("")

        var filesIncluded = 0
        for (file, fileSymbols) in grouped {
            let shortFile = file.components(separatedBy: "/").suffix(3).joined(separator: "/")
            var fileLines: [String] = [shortFile]

            var topLevel: [IndexEntry] = []
            var contained: [String: [IndexEntry]] = [:]

            for sym in fileSymbols {
                if let c = sym.container { contained[c, default: []].append(sym) }
                else { topLevel.append(sym) }
            }

            for sym in topLevel {
                fileLines.append("  \(sym.kind) \(sym.name) L\(sym.startLine)")
                if let members = contained[sym.name] {
                    for m in members {
                        fileLines.append("    \(m.kind) \(m.name) L\(m.startLine)")
                    }
                }
            }

            let fileBlock = fileLines.joined(separator: "\n")
            let totalSoFar = lines.joined(separator: "\n").count
            if totalSoFar + fileBlock.count + 1 > maxChars {
                let remaining = grouped.count - filesIncluded
                lines.append("... \(remaining) more files (use senkani_explore for full tree)")
                break
            }

            lines.append(contentsOf: fileLines)
            filesIncluded += 1
        }

        return lines.joined(separator: "\n")
    }
}
