import Foundation

/// Loads and exposes the set of known `ScheduledPreset`s.
///
/// Two sources:
///   1. Shipped defaults — five JSON records bundled with the `Core`
///      target under `Sources/Core/Presets/Defaults/*.json`. Loaded
///      once, lazily, via `Bundle.module`.
///   2. User presets — `.senkani/presets/*.json` in the operator's
///      home dir. Loaded on each `all()` call so hand-edits land
///      without a restart.
///
/// A user preset with the same `name` as a shipped default shadows
/// the shipped one — operators can customize in place.
public enum PresetCatalog {

    // MARK: - Test-only override

    nonisolated(unsafe) private static var _userDirOverride: String?
    private static let testLock = NSLock()

    /// TEST ONLY: redirect the user-presets directory for the duration
    /// of `body`. Used by `PresetCatalogTests` to drop custom JSON
    /// without touching `$HOME`.
    public static func withUserDir<T>(
        _ dir: String,
        _ body: () throws -> T
    ) rethrows -> T {
        testLock.lock()
        let prior = _userDirOverride
        _userDirOverride = dir
        defer {
            _userDirOverride = prior
            testLock.unlock()
        }
        return try body()
    }

    /// User-presets directory (`~/.senkani/presets` by default; test
    /// override honored).
    public static var userDir: String {
        _userDirOverride
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.senkani/presets")
    }

    // MARK: - Public API

    /// Canonical names of the shipped defaults, in display order.
    public static let shippedNames: [String] = [
        "log-rotation",
        "morning-brief",
        "autoresearch",
        "competitive-scan",
        "senkani-improve"
    ]

    /// Shipped-default presets only. Cached after first decode.
    public static var shipped: [ScheduledPreset] {
        return cachedShipped
    }

    /// Lookup by name. Shipped + user presets, user shadowing shipped.
    public static func find(_ name: String) -> ScheduledPreset? {
        all().first { $0.name == name }
    }

    /// Shipped + user presets, user-shadowing-shipped, sorted so shipped
    /// order is preserved and user-only entries trail in alphabetical
    /// order.
    public static func all() -> [ScheduledPreset] {
        let userPresets = loadUserPresets()
        let userByName = Dictionary(uniqueKeysWithValues: userPresets.map { ($0.name, $0) })
        var seen = Set<String>()
        var out: [ScheduledPreset] = []

        for preset in shipped {
            if let userOverride = userByName[preset.name] {
                out.append(userOverride)
            } else {
                out.append(preset)
            }
            seen.insert(preset.name)
        }

        for preset in userPresets.sorted(by: { $0.name < $1.name }) {
            if !seen.contains(preset.name) {
                out.append(preset)
                seen.insert(preset.name)
            }
        }
        return out
    }

    /// True if `name` identifies a shipped default (regardless of
    /// whether a user preset shadows it). Used by `preset list`
    /// rendering to flag shipped vs user-only.
    public static func isShipped(_ name: String) -> Bool {
        shipped.contains { $0.name == name }
    }

    // MARK: - Internal

    /// Decode a single JSON blob into a `ScheduledPreset`. Exposed so
    /// tests can assert round-trip behavior without reading from disk.
    public static func decode(_ data: Data) throws -> ScheduledPreset {
        try decoder.decode(ScheduledPreset.self, from: data)
    }

    /// Encode a preset back to pretty JSON. Used by `preset show`.
    public static func encode(_ preset: ScheduledPreset) throws -> Data {
        try encoder.encode(preset)
    }

    // MARK: - Shipped cache

    private static let cachedShipped: [ScheduledPreset] = {
        shippedNames.compactMap { name in
            guard let url = Bundle.module.url(
                forResource: name,
                withExtension: "json"
            ) else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(ScheduledPreset.self, from: data)
        }
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    // MARK: - User presets

    private static func loadUserPresets() -> [ScheduledPreset] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: userDir) else { return [] }
        return entries
            .filter { $0.hasSuffix(".json") }
            .compactMap { filename in
                let path = userDir + "/" + filename
                guard let data = fm.contents(atPath: path) else { return nil }
                return try? decoder.decode(ScheduledPreset.self, from: data)
            }
    }
}
