import Foundation

/// Deterministic "has the project changed since time T?" check for
/// command-replay invalidation.
///
/// Why not use the root directory's mtime? macOS only bumps a directory's
/// mtime when its *direct* children change (create, rename, delete). Mutating
/// a nested file — the common case after an `Edit` — does NOT update any
/// ancestor directory's mtime. Using root mtime for invalidation lets stale
/// command output replay after the agent has touched nested files.
///
/// This helper walks the tree and returns the max mtime of any tracked source
/// file. Skipped directories (`.git`, `node_modules`, `.build`, `.senkani`,
/// …) are pruned to keep the walk bounded. Unknown file types are ignored so
/// changes to binary artefacts, logs, etc. don't invalidate replay either.
public enum ProjectFingerprint {

    /// Directories that are always skipped (never contribute to the
    /// fingerprint). Mirror of `Indexer.FileWalker.skipDirs` — duplicated
    /// here so Core doesn't need to depend on Indexer.
    public static let skipDirs: Set<String> = [
        ".git", ".build", ".senkani", "node_modules", "__pycache__",
        ".swiftpm", "build", "DerivedData", ".cache", "vendor",
        "Pods", ".gradle", "target", "dist", ".next",
    ]

    /// Source-file extensions that contribute to the fingerprint. Mirror of
    /// `Indexer.FileWalker.languageMap` keys; duplicated for the same reason.
    public static let trackedExtensions: Set<String> = [
        "swift",
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "py", "go", "rs",
        "java", "kt", "kts",
        "c", "h", "cpp", "cc", "cxx", "hpp", "hh", "hxx",
        "cs", "rb", "php",
        "zig", "lua",
        "sh", "bash", "zsh",
        "scala", "sc",
        "ex", "exs",
        "hs", "lhs",
        "html", "htm", "css",
        "dart", "toml",
        "graphql", "gql",
    ]

    /// Returns the max modification date across all tracked source files
    /// under `projectRoot`, or nil if none were found.
    ///
    /// Walks using `FileManager.enumerator` with `.skipsHiddenFiles`, pruning
    /// any path whose directory segment is in `skipDirs`. The walk is
    /// bounded by project size and is intentionally cheap to call from the
    /// hook path — a moderate project finishes in well under 10ms.
    public static func maxSourceMtime(projectRoot: String) -> Date? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: projectRoot)

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // Symlink resolution matters on macOS: /tmp ↔ /private/tmp. The
        // enumerator may report absolute paths through either namespace
        // depending on how it was constructed, so normalize both sides.
        let resolvedRoot = rootURL.resolvingSymlinksInPath().path
        let rawRoot = rootURL.standardized.path
        let rootPrefixes = Set([resolvedRoot, rawRoot].map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        var maxDate: Date?

        while let obj = enumerator.nextObject() {
            guard let url = obj as? URL else { continue }
            let full = url.resolvingSymlinksInPath().path

            // Relative path for skip-dir check. Anything outside the root
            // (shouldn't happen via enumerator, but defensively handle) is
            // ignored.
            var rel: String?
            for prefix in rootPrefixes where full.hasPrefix(prefix) {
                rel = String(full.dropFirst(prefix.count))
                break
            }
            guard let rel else { continue }

            let components = rel.split(separator: "/").map(String.init)
            if components.dropLast().contains(where: { skipDirs.contains($0) }) {
                continue
            }
            if let top = components.first, skipDirs.contains(top), components.count == 1 {
                // Skip-dir encountered at top level — prune its subtree so we
                // don't even stat its descendants.
                enumerator.skipDescendants()
                continue
            }
            if let top = components.first, skipDirs.contains(top) {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }

            let ext = url.pathExtension.lowercased()
            guard trackedExtensions.contains(ext) else { continue }

            if let mtime = values.contentModificationDate {
                if maxDate == nil || mtime > maxDate! {
                    maxDate = mtime
                }
            }
        }

        return maxDate
    }
}
