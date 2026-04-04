import Foundation

/// Persists the symbol index to disk as JSON.
public enum IndexStore {
    /// Default index path relative to project root.
    public static func indexPath(projectRoot: String) -> String {
        projectRoot + "/.senkani/index.json"
    }

    /// Load an existing index from disk, or return nil if none exists.
    public static func load(projectRoot: String) -> SymbolIndex? {
        let path = indexPath(projectRoot: projectRoot)
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SymbolIndex.self, from: data)
    }

    /// Save the index to disk.
    public static func save(_ index: SymbolIndex, projectRoot: String) throws {
        let path = indexPath(projectRoot: projectRoot)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        try data.write(to: URL(fileURLWithPath: path))
    }

    /// Build or incrementally update the index.
    /// This is the main entry point — handles the full autopilot logic.
    public static func buildOrUpdate(projectRoot: String, force: Bool = false) -> SymbolIndex {
        if !force, let existing = load(projectRoot: projectRoot) {
            return IndexEngine.incrementalUpdate(existing: existing, projectRoot: projectRoot)
        }
        return IndexEngine.index(projectRoot: projectRoot)
    }
}
