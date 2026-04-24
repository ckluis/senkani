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
        "dart",
        "graphql", "gql",
    ]

    /// Basenames (case-sensitive, exact match) of build/test inputs that
    /// also contribute to the fingerprint. A change to any of these shifts
    /// build or test behavior even when no source file was touched, so the
    /// command-replay path must invalidate cached output.
    ///
    /// `.env` is deliberately excluded — it typically holds secrets, and
    /// tracking it would read its mtime on every Bash hook call. `.env.example`
    /// is harmless, but we'd need a second rule to include only that one; not
    /// worth the weight.
    public static let trackedBasenames: Set<String> = [
        // Swift
        "Package.swift", "Package.resolved",
        // Node / TS
        "package.json", "package-lock.json", "yarn.lock", "pnpm-lock.yaml",
        "bun.lockb", "bun.lock", "tsconfig.json", "tsconfig.base.json",
        "vite.config.js", "vite.config.ts", "vite.config.mjs",
        "webpack.config.js", "rollup.config.js",
        // Go
        "go.mod", "go.sum",
        // Rust
        "Cargo.toml", "Cargo.lock",
        // Python
        "pyproject.toml", "poetry.lock", "Pipfile", "Pipfile.lock",
        "setup.py", "setup.cfg", "requirements.txt",
        "requirements-dev.txt", "requirements-test.txt",
        // Ruby
        "Gemfile", "Gemfile.lock", "Rakefile",
        // Make / CMake
        "Makefile", "GNUmakefile", "CMakeLists.txt",
        // Docker / compose
        "Dockerfile", "docker-compose.yml", "docker-compose.yaml",
        // Root-level Senkani config (affects tool routing)
        "senkani.json",
    ]

    /// Trailing-filename patterns that are tracked. Keeps `docker-compose.dev.yml`
    /// etc. in scope without exhaustively listing them.
    public static let trackedBasenameSuffixes: [String] = [
        ".Dockerfile",             // e.g. multi-stage aliases
    ]

    /// Relative-path predicate: any file under `.github/workflows/*.yml`
    /// counts. These change CI behavior and indirectly test outcomes.
    public static func isTrackedCIPath(_ relativePath: String) -> Bool {
        guard relativePath.hasPrefix(".github/workflows/") else { return false }
        return relativePath.hasSuffix(".yml") || relativePath.hasSuffix(".yaml")
    }

    /// `true` when a file at the given relative path + basename should
    /// contribute to the fingerprint.
    public static func isTracked(relativePath: String, basename: String, ext: String) -> Bool {
        if trackedExtensions.contains(ext) { return true }
        if trackedBasenames.contains(basename) { return true }
        for suffix in trackedBasenameSuffixes where basename.hasSuffix(suffix) { return true }
        if isTrackedCIPath(relativePath) { return true }
        return false
    }

    /// Returns the max modification date across all tracked project inputs
    /// under `projectRoot`, or nil if none were found.
    ///
    /// Walks using `FileManager.enumerator` WITHOUT `.skipsHiddenFiles`
    /// because we deliberately want to include `.github/workflows/*.yml`.
    /// Skip-dir pruning still runs first, so `.git` / `.senkani` / `.build`
    /// never enter the walk. Symlink ambiguity (`/tmp` ↔ `/private/tmp`) is
    /// handled on both sides of the prefix check.
    public static func maxSourceMtime(projectRoot: String) -> Date? {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: projectRoot)

        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
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
            if let top = components.first, skipDirs.contains(top) {
                // Skip-dir encountered — prune and skip descendants. Applies
                // at every depth because a skip-dir at any level is still a
                // skip-dir.
                if components.count == 1 { enumerator.skipDescendants() }
                continue
            }
            if components.dropLast().contains(where: { skipDirs.contains($0) }) {
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                  values.isRegularFile == true else { continue }

            let basename = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            guard isTracked(relativePath: rel, basename: basename, ext: ext) else { continue }

            if let mtime = values.contentModificationDate {
                if maxDate == nil || mtime > maxDate! {
                    maxDate = mtime
                }
            }
        }

        return maxDate
    }
}
