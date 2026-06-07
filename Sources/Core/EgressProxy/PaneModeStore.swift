import Foundation

/// Per-pane mode store backing `HookRouter.paneModeResolver` (T.1b
/// follow-up). Persists `pane_id → PaneMode` mappings to
/// `~/.senkani/pane-modes.json` and serves synchronous lookups from an
/// in-memory cache. The file is operator-editable; absent or malformed
/// file → every pane resolves to `.general` (Schneier 2026-05-19:
/// silent default, no log spam, no panic).
///
/// Concurrency: NSLock-guarded snapshot; `resolve` is cheap and safe
/// to call from any thread, including the EgressProxy's hot path and
/// HookRouter's PreToolUse closure path. Writes are rare (operator
/// pane-mode toggle UI / future CLI) and reload from disk on demand.
public final class PaneModeStore: @unchecked Sendable {

    /// Process-wide store. Tests construct their own instance pointing
    /// at a temp file path.
    public static let shared = PaneModeStore()

    /// Default file path. Operator-editable. Tests override via init.
    public static let defaultPath = NSHomeDirectory() + "/.senkani/pane-modes.json"

    /// On-disk wire shape. Top-level dict of `pane_id` → mode rawValue.
    /// Unknown mode strings or pane_id keys fall back to `.general`.
    private struct Wire: Codable {
        var modes: [String: String]
    }

    private let lock = NSLock()
    private let path: String
    private var cache: [String: PaneMode]
    private var loaded: Bool

    public init(path: String = PaneModeStore.defaultPath) {
        self.path = path
        self.cache = [:]
        self.loaded = false
    }

    /// Resolve a pane's mode. Default = `.general` for any unknown
    /// pane id (or when the on-disk file is missing/malformed/empty).
    public func resolve(paneID: String?) -> PaneMode {
        guard let paneID, !paneID.isEmpty else { return .default }
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loadLocked()
            loaded = true
        }
        return cache[paneID] ?? .default
    }

    /// Update a pane's mode and persist to disk atomically. A nil mode
    /// removes the override (pane reverts to `.general`).
    @discardableResult
    public func setMode(paneID: String, mode: PaneMode?) -> Bool {
        guard !paneID.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        if !loaded {
            loadLocked()
            loaded = true
        }
        if let mode {
            cache[paneID] = mode
        } else {
            cache.removeValue(forKey: paneID)
        }
        return persistLocked()
    }

    /// Drop the in-memory snapshot. Next `resolve` re-reads the file.
    /// Tests use this to assert load-from-disk after editing the file
    /// directly.
    public func invalidateCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
        loaded = false
    }

    // MARK: - Private (must be called under `lock`)

    private func loadLocked() {
        cache.removeAll()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else {
            return
        }
        for (paneID, raw) in wire.modes {
            if let mode = PaneMode(rawValue: raw) {
                cache[paneID] = mode
            }
        }
    }

    private func persistLocked() -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let wire = Wire(modes: cache.reduce(into: [String: String]()) { acc, kv in
            acc[kv.key] = kv.value.rawValue
        })
        guard let data = try? JSONEncoder().encode(wire) else { return false }
        let tmp = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])
            rename(tmp, path)
            return true
        } catch {
            return false
        }
    }
}
