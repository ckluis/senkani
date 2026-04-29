import Foundation

// MARK: - KBVaultMigrator
//
// V.7 — copy markdown vault contents between two directories. Used to
// move a project's KB out of `<projectRoot>/.senkani/knowledge` into
// the configured external vault (`migrate`) and to roll the move back
// (`unmigrate`).
//
// Idempotency rules:
//   - Skip dest files whose contents already match the source byte-for-byte
//     (SHA-256 compare).
//   - Conflicts (dest exists with different content) are reported but never
//     overwritten — operator chooses how to merge.
//   - .staged/ and .history/ are not migrated. Staged files are operator
//     in-flight edits that should be resolved before relocating; history is
//     archive metadata that doesn't need to follow the live vault.

public enum KBVaultMigrator {

    public struct Report: Sendable, Equatable {
        public let copied: [String]      // filenames migrated this pass
        public let skipped: [String]     // already-present, content-identical files
        public let conflicts: [String]   // dest exists with different content; left alone

        public var isEmpty: Bool { copied.isEmpty && skipped.isEmpty && conflicts.isEmpty }
        public var hasConflicts: Bool { !conflicts.isEmpty }
    }

    /// Copy every `*.md` file directly under `sourceDir` into `destDir`.
    /// Creates `destDir` if missing. Pure copy — does NOT delete source.
    /// Use `removeSourceAfter: true` only after the operator has verified
    /// the migration; the CLI exposes this as the `--prune` flag.
    @discardableResult
    public static func migrate(
        from sourceDir: String,
        to destDir: String,
        removeSourceAfter: Bool = false,
        fileManager fm: FileManager = .default
    ) throws -> Report {
        try fm.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        var copied: [String] = []
        var skipped: [String] = []
        var conflicts: [String] = []

        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: sourceDir)
        } catch {
            // Source dir absent → nothing to migrate, that's fine for an empty project.
            return Report(copied: [], skipped: [], conflicts: [])
        }

        for name in entries.sorted() where name.hasSuffix(".md") {
            let src = sourceDir + "/" + name
            let dst = destDir + "/" + name

            guard let srcData = try? Data(contentsOf: URL(fileURLWithPath: src)) else { continue }

            if fm.fileExists(atPath: dst) {
                let dstData = (try? Data(contentsOf: URL(fileURLWithPath: dst))) ?? Data()
                if srcData == dstData {
                    skipped.append(name)
                    if removeSourceAfter { try? fm.removeItem(atPath: src) }
                    continue
                } else {
                    conflicts.append(name)
                    continue   // never silently overwrite operator data
                }
            }

            try atomicWrite(srcData, to: dst)
            copied.append(name)
            if removeSourceAfter { try? fm.removeItem(atPath: src) }
        }

        return Report(copied: copied, skipped: skipped, conflicts: conflicts)
    }

    /// Reverse direction of `migrate`. Equivalent to `migrate(from: dest, to: source)`
    /// when `prune == false`; with `prune == true` it removes the externalized
    /// copies after restoring the project-local copies.
    @discardableResult
    public static func unmigrate(
        from externalDir: String,
        to projectDir: String,
        removeSourceAfter: Bool = false,
        fileManager fm: FileManager = .default
    ) throws -> Report {
        return try migrate(
            from: externalDir, to: projectDir,
            removeSourceAfter: removeSourceAfter, fileManager: fm)
    }

    // MARK: - Private

    private static func atomicWrite(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp)
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
