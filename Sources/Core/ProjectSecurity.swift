import Foundation

/// Security utilities for multi-repo project path handling.
///
/// Addresses:
/// - Path traversal / symlink escape attacks
/// - App Sandbox compatibility via security-scoped bookmarks
/// - Credential leakage through path logging
/// - Invalid or inaccessible project directories
public enum ProjectSecurity {

    // MARK: - Errors

    public enum SecurityError: Error, CustomStringConvertible {
        case pathDoesNotExist(String)
        case notADirectory(String)
        case notReadable(String)
        case symlinkEscape(resolved: String, original: String)
        case bookmarkCreationFailed(String)
        case bookmarkResolutionFailed(String)
        case pathContainsDangerousComponents(String)

        public var description: String {
            switch self {
            case .pathDoesNotExist(let p):
                return "Project path does not exist: \(Self.sanitizedPath(p))"
            case .notADirectory(let p):
                return "Project path is not a directory: \(Self.sanitizedPath(p))"
            case .notReadable(let p):
                return "Project path is not readable: \(Self.sanitizedPath(p))"
            case .symlinkEscape(let resolved, let original):
                return "Symlink escape detected: \(Self.sanitizedPath(original)) resolves outside expected scope to \(Self.sanitizedPath(resolved))"
            case .bookmarkCreationFailed(let msg):
                return "Failed to create security-scoped bookmark: \(msg)"
            case .bookmarkResolutionFailed(let msg):
                return "Failed to resolve security-scoped bookmark: \(msg)"
            case .pathContainsDangerousComponents(let p):
                return "Path contains dangerous components: \(Self.sanitizedPath(p))"
            }
        }

        /// Redact the home directory username from paths before logging.
        private static func sanitizedPath(_ path: String) -> String {
            return ProjectSecurity.redactPath(path)
        }
    }

    // MARK: - Allowed Root Directories

    /// Directories under which project paths are considered safe.
    /// Symlink resolution must land within one of these roots.
    private static let allowedRoots: [String] = {
        var roots: [String] = []
        // User's home directory and subdirectories
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            roots.append(home)
        }
        roots.append(NSHomeDirectory())
        // Common development locations
        roots.append("/tmp")
        roots.append("/private/tmp")
        // Volumes (external drives)
        roots.append("/Volumes")
        return roots
    }()

    // MARK: - Path Validation

    /// Validates a project directory path.
    ///
    /// Checks performed:
    /// 1. Path must not contain dangerous components (.. after normalization, null bytes)
    /// 2. Path must exist on disk
    /// 3. Path must be a directory (not a file)
    /// 4. Path must be readable by the current process
    /// 5. Symlinks are resolved; resolved path must stay within allowed roots
    ///
    /// - Parameter path: The raw path string from user input.
    /// - Returns: A validated, resolved file URL.
    /// - Throws: `SecurityError` if any check fails.
    public static func validateProjectPath(_ path: String) throws -> URL {
        // Reject null bytes (could truncate C strings in file operations)
        guard !path.contains("\0") else {
            throw SecurityError.pathContainsDangerousComponents(path)
        }

        // Expand ~ and standardize
        let expanded = NSString(string: path).expandingTildeInPath
        let standardized = NSString(string: expanded).standardizingPath

        // Check for remaining suspicious components after standardization
        let components = standardized.split(separator: "/").map(String.init)
        if components.contains("..") {
            throw SecurityError.pathContainsDangerousComponents(path)
        }

        let fm = FileManager.default

        // Check existence
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized, isDirectory: &isDir) else {
            throw SecurityError.pathDoesNotExist(standardized)
        }

        // Must be a directory
        guard isDir.boolValue else {
            throw SecurityError.notADirectory(standardized)
        }

        // Must be readable
        guard fm.isReadableFile(atPath: standardized) else {
            throw SecurityError.notReadable(standardized)
        }

        // Resolve symlinks to detect escape attacks
        let url = URL(fileURLWithPath: standardized).standardized
        let resolved = url.resolvingSymlinksInPath()
        let resolvedPath = resolved.path

        // Verify resolved path is within an allowed root
        let isAllowed = allowedRoots.contains { root in
            resolvedPath.hasPrefix(root + "/") || resolvedPath == root
        }
        guard isAllowed else {
            throw SecurityError.symlinkEscape(resolved: resolvedPath, original: standardized)
        }

        return resolved
    }

    // MARK: - Security-Scoped Bookmarks (App Sandbox)

    /// Creates a security-scoped bookmark for a validated project URL.
    ///
    /// This bookmark can be persisted (e.g., in UserDefaults or a database)
    /// and later resolved to regain access to the directory even across app restarts
    /// in a sandboxed environment.
    ///
    /// - Parameter url: A validated project directory URL.
    /// - Returns: Bookmark data that can be stored.
    /// - Throws: `SecurityError.bookmarkCreationFailed` on failure.
    public static func createBookmark(for url: URL) throws -> Data {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return data
        } catch {
            throw SecurityError.bookmarkCreationFailed(error.localizedDescription)
        }
    }

    /// Resolves a previously created security-scoped bookmark back to a URL.
    ///
    /// If the bookmark is stale, the caller should re-prompt the user and create
    /// a new bookmark. The returned URL has `startAccessingSecurityScopedResource()`
    /// already called — the caller MUST call `stopAccessingSecurityScopedResource()`
    /// when done.
    ///
    /// - Parameter data: Bookmark data from `createBookmark(for:)`.
    /// - Returns: The resolved, access-started URL.
    /// - Throws: `SecurityError.bookmarkResolutionFailed` on failure.
    public static func resolveBookmark(_ data: Data) throws -> URL {
        var isStale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw SecurityError.bookmarkResolutionFailed(error.localizedDescription)
        }

        if isStale {
            throw SecurityError.bookmarkResolutionFailed("Bookmark is stale — re-prompt user for access")
        }

        // Start accessing the security-scoped resource
        guard url.startAccessingSecurityScopedResource() else {
            throw SecurityError.bookmarkResolutionFailed("Failed to start accessing security-scoped resource")
        }

        // Re-validate the resolved path (directory may have been moved/changed)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            url.stopAccessingSecurityScopedResource()
            throw SecurityError.bookmarkResolutionFailed("Bookmarked path no longer exists or is not a directory")
        }

        return url
    }

    // MARK: - Path Redaction for Logging

    /// Redacts sensitive information from paths before logging or displaying in diagnostics.
    ///
    /// Replaces the home directory path with ~ and obscures the username.
    /// e.g., "/Users/johndoe/Projects/foo" becomes "~/Projects/foo"
    public static func redactPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        // Also catch /Users/<username> patterns where home might differ
        let components = path.split(separator: "/")
        if components.count >= 2, components[0] == "Users" {
            // Replace username with "***"
            var redacted = components
            redacted[1] = "***"
            return "/" + redacted.joined(separator: "/")
        }
        return path
    }
}
