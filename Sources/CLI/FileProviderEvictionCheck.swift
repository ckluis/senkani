import Darwin
import Foundation

/// Result of a `FileProviderEvictionScanner.scan(...)` walk.
///
/// `hasFinding` is `true` if any of the three signals fired
/// (FileProvider ancestry, `SF_DATALESS` files, `* 2` Finder shadows).
/// The doctor surface routes this report through
/// `Doctor.formatFileProviderEvictionLines(_:)` — the pure formatter
/// keeps tests free of stdout-capture and lets the integration tests
/// inject synthesized reports for the privileged paths (the
/// `SF_DATALESS` flag is FileProvider-only and cannot be set from
/// user space).
public struct FileProviderEvictionReport: Sendable, Equatable {
    public var scannedRoot: String
    public var pathUnderFileProvider: Bool
    public var datalessPaths: [String]
    public var star2Siblings: [String]

    public var hasFinding: Bool {
        pathUnderFileProvider
            || !datalessPaths.isEmpty
            || !star2Siblings.isEmpty
    }

    public init(
        scannedRoot: String,
        pathUnderFileProvider: Bool = false,
        datalessPaths: [String] = [],
        star2Siblings: [String] = []
    ) {
        self.scannedRoot = scannedRoot
        self.pathUnderFileProvider = pathUnderFileProvider
        self.datalessPaths = datalessPaths
        self.star2Siblings = star2Siblings
    }
}

/// Detects iCloud-Drive / FileProvider eviction symptoms on a project
/// tree. Three signals:
///
/// 1. The project root sits under a FileProvider-managed path
///    (Desktop & Documents iCloud sync, or `~/Library/Mobile
///    Documents/`).
/// 2. `.build/checkouts/` contains files with the `SF_DATALESS`
///    `st_flag` (APFS sentinel for "content is evicted to a cloud
///    provider; metadata is on disk").
/// 3. `.build/checkouts/`, `Sources/`, `Tests/`, `docs/` contain
///    `* 2` Finder-shadow siblings (iCloud sync conflict resolution).
///
/// See `build-env-swiftpm-checkout-corruption-icloud-eviction-2026-05-09`
/// for the originating incident.
public enum FileProviderEvictionScanner {

    /// `SF_DATALESS = 0x40000000` — Darwin/APFS system flag set by
    /// FileProvider when a file's content has been evicted to a cloud
    /// provider but the metadata remains on disk. Hard-coded because
    /// the symbol isn't reliably exposed through Swift's Darwin module.
    public static let SF_DATALESS_FLAG: UInt32 = 0x4000_0000

    public static func scan(root: String) -> FileProviderEvictionReport {
        let underFileProvider = pathUnderFileProvider(path: root)
        var datalessPaths: [String] = []
        var star2Siblings: [String] = []

        let fm = FileManager.default

        // Shallow scan of `.build/checkouts/` (the documented
        // recurrence surface — see the incident inventory).
        let checkouts = (root as NSString).appendingPathComponent(".build/checkouts")
        if let entries = try? fm.contentsOfDirectory(atPath: checkouts) {
            for entry in entries {
                let full = (checkouts as NSString).appendingPathComponent(entry)
                let rel = ".build/checkouts/" + entry
                if matchesStar2Pattern(entry) {
                    star2Siblings.append(rel)
                }
                if datalessFlagSet(path: full) {
                    datalessPaths.append(rel)
                }
                // One-level deep: probe each package's top-level
                // files for SF_DATALESS, the Phase-1-incident pattern.
                if let pkgEntries = try? fm.contentsOfDirectory(atPath: full) {
                    for sub in pkgEntries {
                        let subFull = (full as NSString).appendingPathComponent(sub)
                        if datalessFlagSet(path: subFull) {
                            datalessPaths.append(rel + "/" + sub)
                        }
                    }
                }
            }
        }

        // Recursive scan of operator-tracked source roots for `* 2`
        // shadows. Tests/ and docs/ have shipped these in the past;
        // Sources/ has too. The walk stops at hidden directories
        // (skips `.git/`, `.build/` itself).
        for subdir in ["Sources", "Tests", "docs"] {
            let dir = (root as NSString).appendingPathComponent(subdir)
            guard fm.fileExists(atPath: dir) else { continue }
            let url = URL(fileURLWithPath: dir)
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let fileURL as URL in enumerator {
                let name = fileURL.lastPathComponent
                guard matchesStar2Pattern(name) else { continue }
                let path = fileURL.path
                if path.hasPrefix(root + "/") {
                    star2Siblings.append(String(path.dropFirst(root.count + 1)))
                } else {
                    star2Siblings.append(path)
                }
            }
        }

        return FileProviderEvictionReport(
            scannedRoot: root,
            pathUnderFileProvider: underFileProvider,
            datalessPaths: datalessPaths,
            star2Siblings: star2Siblings
        )
    }

    /// Multi-signal probe for "is this path under FileProvider?":
    ///
    /// 1. Ancestor path is `~/Library/Mobile Documents/` (the iCloud
    ///    Drive root proper).
    /// 2. The path itself or its root carries the
    ///    `com.apple.metadata:com_apple_clouddocs` xattr (Desktop &
    ///    Documents Sync sentinel).
    /// 3. `URL.resourceValues(forKeys: [.isUbiquitousItemKey])` returns
    ///    `isUbiquitousItem == true`.
    public static func pathUnderFileProvider(path: String) -> Bool {
        let mobileDocs = NSHomeDirectory() + "/Library/Mobile Documents"
        let resolved = (path as NSString).standardizingPath
        if resolved.hasPrefix(mobileDocs) { return true }

        if hasCloudDocsXattr(path: path) { return true }

        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey]),
           values.isUbiquitousItem == true {
            return true
        }
        return false
    }

    /// Read `st_flags` via `lstat()` (don't follow symlinks) and check
    /// the `SF_DATALESS` bit. Returns `false` if the path doesn't exist
    /// or `lstat` fails (the doctor surface treats absent paths as
    /// silent — the scanner only reports flags it actually saw).
    public static func datalessFlagSet(path: String) -> Bool {
        var st = Darwin.stat()
        guard lstat(path, &st) == 0 else { return false }
        return (st.st_flags & SF_DATALESS_FLAG) != 0
    }

    /// `* 2` Finder-shadow filename matcher. Matches names that end in
    /// ` 2` or ` 2.<ext>` (single-extension only, the macOS Finder
    /// pattern). Counter-examples that should NOT match: `Foo2.swift`,
    /// `version-2.swift`, `Foo 23.swift`.
    public static func matchesStar2Pattern(_ name: String) -> Bool {
        // Pattern: ^.+ 2(\.[^.]+)?$
        // - `.+ ` requires at least one char then a literal space.
        // - `2` literal.
        // - Optional `.<ext>` where ext is non-dot chars.
        // - End of string.
        guard name.count >= 3 else { return false }
        // Find the last " 2" occurrence and verify it's followed by
        // either end-of-string or a single-extension dot+chars-no-dot.
        if name.hasSuffix(" 2") {
            // No extension form: `Foo 2`. Require length > 2 (a name char before the space).
            return name.count > 2 && !name.hasPrefix(" 2")
        }
        // Extension form: search for " 2." and confirm the rest is one dot-free segment.
        guard let range = name.range(of: " 2.") else { return false }
        let head = name[..<range.lowerBound]  // up to but excluding " "
        guard !head.isEmpty else { return false }
        let tail = name[range.upperBound...]  // after the dot
        return !tail.isEmpty && !tail.contains(".")
    }

    private static func hasCloudDocsXattr(path: String) -> Bool {
        // `getxattr` returns the value size on success or -1 on failure
        // (e.g., ENOATTR when the attribute is absent). A non-negative
        // result means the attribute exists.
        let key = "com.apple.metadata:com_apple_clouddocs"
        let size = path.withCString { cPath in
            key.withCString { cKey in
                getxattr(cPath, cKey, nil, 0, 0, 0)
            }
        }
        return size >= 0
    }
}
