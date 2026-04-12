import Foundation

/// A project's import dependency graph.
/// Built by extracting import statements from each source file via tree-sitter.
public struct DependencyGraph: Codable, Sendable {
    /// file (relative path) → [modules/files it imports]
    public let imports: [String: [String]]
    /// module identifier → [files that import it]
    public let importedBy: [String: [String]]
    /// When the graph was built
    public let generated: Date
    /// Project root used to build the graph
    public let projectRoot: String

    public init(
        imports: [String: [String]] = [:],
        importedBy: [String: [String]] = [:],
        projectRoot: String = "",
        generated: Date = Date()
    ) {
        self.imports = imports
        self.importedBy = importedBy
        self.projectRoot = projectRoot
        self.generated = generated
    }

    /// Query: what does this file import?
    /// Accepts an exact relative path or a substring (e.g., "MCPSession.swift").
    public func dependencies(of file: String) -> [String] {
        if let exact = imports[file] { return exact }
        // Substring fallback
        let matches = imports.filter { $0.key.contains(file) }
        return matches.flatMap(\.value).sorted()
    }

    /// Query: what files import this module/file?
    /// Accepts an exact module name or a substring.
    public func dependents(of target: String) -> [String] {
        if let exact = importedBy[target] { return exact }
        // Case-insensitive substring fallback
        let lower = target.lowercased()
        var results: Set<String> = []
        for (key, files) in importedBy where key.lowercased().contains(lower) {
            results.formUnion(files)
        }
        return results.sorted()
    }
}
