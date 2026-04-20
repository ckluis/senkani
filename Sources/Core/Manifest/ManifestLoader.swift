import Foundation

/// Reads the committed team manifest + this user's local overrides
/// from disk and returns the resolved `EffectiveSet`.
///
/// Both files are JSON (see `Manifest.swift` for the YAML/JSON
/// rationale). Missing files are not errors — a project with no
/// `.senkani/senkani.json` gets `manifestPresent: false` and falls
/// back to today's "all tools enabled" behavior via
/// `EffectiveSet.isToolEnabled(_:)`.
public enum ManifestLoader {
    /// Load the resolved effective set for `projectRoot`.
    ///
    /// - Parameters:
    ///   - projectRoot: absolute path to the project root. Used to
    ///     locate `<projectRoot>/.senkani/senkani.json` and to key
    ///     into the per-user overrides file.
    ///   - overridesURL: path to the user overrides file. Defaults
    ///     to `~/.senkani/overrides.json`. Override in tests.
    public static func load(
        projectRoot: String,
        overridesURL: URL = defaultOverridesURL()
    ) -> EffectiveSet {
        let manifest = loadManifest(projectRoot: projectRoot)
        let allOverrides = loadOverrides(at: overridesURL)
        let ours = allOverrides[projectRoot] ?? .empty
        return ManifestResolver.resolve(manifest: manifest, overrides: ours)
    }

    static func loadManifest(projectRoot: String) -> Manifest? {
        let path = projectRoot + "/.senkani/senkani.json"
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    /// The full overrides file — a map from absolute project-root
    /// path to that project's overrides entry.
    static func loadOverrides(at url: URL) -> [String: ManifestOverrides] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: ManifestOverrides].self, from: data)) ?? [:]
    }

    public static func defaultOverridesURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".senkani")
            .appendingPathComponent("overrides.json")
    }
}
