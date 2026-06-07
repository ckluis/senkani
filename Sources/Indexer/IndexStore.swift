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

    /// Save the index to disk and update the FTS5 search store.
    ///
    /// Silently returns if `projectRoot` no longer exists on disk. The
    /// `createDirectory(withIntermediateDirectories: true)` call below
    /// would otherwise resurrect a vanished project root as a side effect
    /// of creating `<projectRoot>/.senkani/`. Two callers race this:
    /// `MCPSession.warmIndex`'s detached Task can outlive a test's
    /// `defer cleanup(dir)` and rematerialize the temp dir
    /// (`mcp-session-warmindex-detached-task-races-test-cleanup-2026-05-18`,
    /// 2026-05-19); and in production a `git checkout` / project-move can
    /// transiently delete the root mid-save. Either way, recreating a
    /// vanished root is wrong — the existing `try?` callers already
    /// swallowed the post-recreation throw, so making the guard a no-op
    /// matches their semantics.
    public static func save(_ index: SymbolIndex, projectRoot: String) throws {
        guard FileManager.default.fileExists(atPath: projectRoot) else { return }
        let path = indexPath(projectRoot: projectRoot)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(index)
        try data.write(to: URL(fileURLWithPath: path))

        // Non-fatal: FTS is a ranking enhancement; JSON is the source of truth.
        try? SymbolFTSStore(projectRoot: projectRoot).rebuild(entries: index.symbols)
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
