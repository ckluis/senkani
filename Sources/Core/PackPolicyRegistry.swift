import Foundation

/// V.11b — In-process registry of HookRouter policy fragments loaded
/// from installed SkillPacks.
///
/// The registry reads `<install-root>/<pack>/policy/hook_router.json`
/// for every pack present on disk and exposes an `evaluate(toolName:
/// toolInput:)` query that the live HookRouter consults before its
/// per-tool routing branches.
///
/// Refresh strategy:
///
///   * `refresh()` — unconditional re-read. PackInstaller calls this
///     on `apply()` / `uninstall()` so same-process installs see
///     their own fragments fire on the very next hook event.
///   * `refreshIfStale()` — cheap mtime check on the install root;
///     re-reads only when the directory tree has changed since the
///     last snapshot. The HookRouter calls this on every
///     `handle(eventJSON:)` so cross-process installs (CLI mutates
///     the install root, daemon serves hook events) converge without
///     restart.
///
/// All match logic is substring-based on the primary input string
/// for the tool: `command` for Bash, `file_path` for Edit/Write/Read,
/// `pattern` for Grep. Regex / glob / structured matchers are a
/// V.11c extension point.
public final class PackPolicyRegistry: @unchecked Sendable {

    /// Process-wide instance. Tests reach in via `setInstallRoot(_:)`
    /// to point at a temp directory and call `refresh()` to load.
    public static let shared = PackPolicyRegistry()

    /// One pack's contribution to the registry.
    public struct LoadedPack: Sendable, Equatable {
        public let packName: String
        public let scopeKey: String
        public let rules: [HookRouterFragment.Rule]
    }

    /// A successful match against the registry.
    public struct Match: Sendable, Equatable {
        public let packName: String
        public let scopeKey: String
        public let rule: HookRouterFragment.Rule
    }

    private let lock = NSLock()
    private var packs: [LoadedPack] = []
    private var explicitInstallRoot: URL?
    /// Snapshot mtime of the install-root directory. `.distantPast`
    /// means "never scanned" so `refreshIfStale` always reloads on
    /// first call.
    private var lastSnapshotMtime: Date = .distantPast

    public init(installRoot: URL? = nil) {
        self.explicitInstallRoot = installRoot
    }

    /// Set the install root. Passing `nil` reverts to the default
    /// `~/.senkani/packs/`. Resets the staleness clock so the next
    /// `refreshIfStale()` will reload.
    public func setInstallRoot(_ url: URL?) {
        lock.lock()
        explicitInstallRoot = url
        lastSnapshotMtime = .distantPast
        lock.unlock()
    }

    /// Currently effective install root.
    public func installRoot() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return effectiveRootLocked()
    }

    /// Number of currently loaded packs (read-only snapshot).
    public func loadedCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return packs.count
    }

    /// Snapshot of the loaded packs. Returns by value; safe to
    /// inspect off the lock.
    public func snapshot() -> [LoadedPack] {
        lock.lock()
        defer { lock.unlock() }
        return packs
    }

    /// Force re-read the install root and replace the loaded packs.
    public func refresh() {
        lock.lock()
        let root = effectiveRootLocked()
        let loaded = Self.scan(root: root)
        packs = loaded
        lastSnapshotMtime = Self.directoryMtime(root) ?? Date()
        lock.unlock()
    }

    /// Re-read only if the install-root mtime has advanced since the
    /// last snapshot. Cheap (one stat call); safe to invoke on every
    /// hook event.
    public func refreshIfStale() {
        lock.lock()
        let root = effectiveRootLocked()
        guard let mtime = Self.directoryMtime(root) else {
            // Install root absent — clear any stale state, but only
            // if we previously had something loaded.
            if !packs.isEmpty {
                packs = []
                lastSnapshotMtime = .distantPast
            }
            lock.unlock()
            return
        }
        if mtime > lastSnapshotMtime {
            packs = Self.scan(root: root)
            lastSnapshotMtime = mtime
        }
        lock.unlock()
    }

    /// Evaluate a tool call against the loaded fragments. Returns the
    /// first matching deny rule, or nil if none match.
    public func evaluate(toolName: String, toolInput: [String: Any]) -> Match? {
        lock.lock()
        let snapshot = packs
        lock.unlock()
        guard !snapshot.isEmpty else { return nil }

        let haystack = Self.primaryHaystack(toolName: toolName, toolInput: toolInput)
        guard !haystack.isEmpty else { return nil }

        for pack in snapshot {
            for rule in pack.rules where rule.kind == "deny" {
                if !rule.match.isEmpty, haystack.contains(rule.match) {
                    return Match(
                        packName: pack.packName,
                        scopeKey: pack.scopeKey,
                        rule: rule)
                }
            }
        }
        return nil
    }

    // MARK: - Internals

    private func effectiveRootLocked() -> URL {
        if let explicit = explicitInstallRoot { return explicit }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".senkani/packs", isDirectory: true)
    }

    /// Walk `root/<pack>/policy/hook_router.json` for every entry
    /// that has both a readable `pack.json` and a parseable policy
    /// fragment. Packs without a policy fragment contribute nothing
    /// to the registry (they are still installed, just policy-less).
    static func scan(root: URL) -> [LoadedPack] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let entries = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var loaded: [LoadedPack] = []
        for entry in entries.sorted() {
            let dir = root.appendingPathComponent(entry, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }
            let packJson = dir.appendingPathComponent("pack.json")
            guard let manifest = try? PackManifestParser.load(from: packJson) else {
                continue
            }
            guard let policy = manifest.policy else { continue }
            let fragmentURL = dir.appendingPathComponent(policy)
            guard let fragment = try? HookRouterFragmentParser.load(from: fragmentURL) else {
                continue
            }
            loaded.append(LoadedPack(
                packName: manifest.name,
                scopeKey: fragment.scopeKey,
                rules: fragment.rules))
        }
        return loaded
    }

    static func directoryMtime(_ url: URL) -> Date? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return nil }
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return mtime
    }

    /// Pick the primary string field for a tool. Pack rules match
    /// against this single field. The set of recognised tools is
    /// intentionally small — V.11b ships substring matching against
    /// the operations agents drive most often (Bash, Edit, Write,
    /// Read, Grep). Unrecognised tools fall through to a best-effort
    /// scan of `command` then `file_path`.
    static func primaryHaystack(
        toolName: String, toolInput: [String: Any]
    ) -> String {
        switch toolName {
        case "Bash":
            return (toolInput["command"] as? String) ?? ""
        case "Edit", "Write", "MultiEdit":
            // Edits expose both file_path and content; rules want
            // to match against either, so concatenate.
            let path = (toolInput["file_path"] as? String) ?? ""
            let content = (toolInput["content"] as? String)
                ?? (toolInput["new_string"] as? String)
                ?? ""
            if content.isEmpty { return path }
            if path.isEmpty { return content }
            return path + "\n" + content
        case "Read":
            return (toolInput["file_path"] as? String) ?? ""
        case "Grep":
            return (toolInput["pattern"] as? String) ?? ""
        default:
            return (toolInput["command"] as? String)
                ?? (toolInput["file_path"] as? String)
                ?? ""
        }
    }
}
