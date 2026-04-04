import Foundation
import Core

/// Represents a project directory in the multi-repo workspace.
/// Each project owns a set of panes and tracks aggregate savings.
///
/// SECURITY: Project paths are validated through ProjectSecurity on creation.
/// Security-scoped bookmarks are used for App Sandbox compatibility.
/// Path logging uses redacted paths to prevent credential leakage.
@Observable
final class ProjectModel: Identifiable {
    let id = UUID()
    var name: String

    /// Validated, symlink-resolved absolute path to project root.
    /// Set only through `init(name:validatedURL:)` or `create(name:path:)`.
    private(set) var path: String

    /// Security-scoped bookmark data for App Sandbox persistence.
    /// Callers should persist this and use `ProjectSecurity.resolveBookmark()`
    /// to regain access across app launches.
    private(set) var bookmarkData: Data?

    var panes: [PaneModel] = []
    var isActive: Bool = false

    /// Total bytes saved across all panes in this project.
    var totalSavedBytes: Int { panes.reduce(0) { $0 + $1.metrics.savedBytes } }

    /// Total raw bytes across all panes in this project.
    var totalRawBytes: Int { panes.reduce(0) { $0 + $1.metrics.totalRawBytes } }

    /// Savings percentage for this project.
    var savingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(totalSavedBytes) / Double(totalRawBytes) * 100
    }

    /// Formatted savings string (e.g. "12.4K").
    var formattedSavings: String {
        let bytes = totalSavedBytes
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    /// Total command count across all panes.
    var totalCommandCount: Int {
        panes.reduce(0) { $0 + $1.metrics.commandCount }
    }

    /// Redacted path safe for logging/display (replaces username with ~).
    var redactedPath: String {
        ProjectSecurity.redactPath(path)
    }

    /// Internal initializer for trusted paths (e.g., the implicit default project).
    /// External callers should use `create(name:path:)` for validated construction.
    init(name: String, trustedPath: String) {
        self.name = name
        self.path = trustedPath
        self.bookmarkData = nil
    }

    /// Initializer with a pre-validated URL and optional bookmark.
    private init(name: String, validatedURL: URL, bookmark: Data?) {
        self.name = name
        self.path = validatedURL.path
        self.bookmarkData = bookmark
    }

    /// Creates a validated project from a raw path string.
    ///
    /// SECURITY: Validates the path through ProjectSecurity which checks:
    /// - Path existence, directory type, readability
    /// - Symlink resolution (prevents escape attacks)
    /// - Creates a security-scoped bookmark for sandbox persistence
    ///
    /// - Parameters:
    ///   - name: Display name (or nil to auto-detect).
    ///   - path: Raw path string from user input.
    /// - Returns: A validated ProjectModel.
    /// - Throws: `ProjectSecurity.SecurityError` if validation fails.
    static func create(name: String? = nil, path: String) throws -> ProjectModel {
        // Validate and resolve the path
        let validatedURL = try ProjectSecurity.validateProjectPath(path)

        // Create security-scoped bookmark for sandbox persistence
        let bookmark = try? ProjectSecurity.createBookmark(for: validatedURL)

        // Auto-detect name if not provided
        let projectName = name ?? detectName(at: validatedURL)

        return ProjectModel(name: projectName, validatedURL: validatedURL, bookmark: bookmark)
    }

    /// Restores a project from a persisted security-scoped bookmark.
    ///
    /// - Parameters:
    ///   - name: Display name.
    ///   - bookmarkData: Previously persisted bookmark data.
    /// - Returns: A restored ProjectModel with active security scope.
    /// - Throws: `ProjectSecurity.SecurityError` if bookmark is stale or invalid.
    static func restore(name: String, bookmarkData: Data) throws -> ProjectModel {
        let url = try ProjectSecurity.resolveBookmark(bookmarkData)
        // Re-create bookmark in case the old one was close to stale
        let newBookmark = try? ProjectSecurity.createBookmark(for: url)
        return ProjectModel(name: name, validatedURL: url, bookmark: newBookmark ?? bookmarkData)
    }

    /// Auto-detect the project name from a validated directory URL.
    ///
    /// SECURITY: Only reads CLAUDE.md and package.json from the validated path.
    /// File reads are size-limited to prevent memory exhaustion from
    /// adversarial project directories.
    private static func detectName(at url: URL) -> String {
        let maxDetectionFileSize = 65_536  // 64KB limit for name detection files

        // Try CLAUDE.md — look for a "# ProjectName" header
        let claudeMd = url.appendingPathComponent("CLAUDE.md")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: claudeMd.path),
           let size = attrs[.size] as? Int, size <= maxDetectionFileSize,
           let contents = try? String(contentsOf: claudeMd, encoding: .utf8) {
            let lines = contents.components(separatedBy: .newlines)
            if let header = lines.first(where: { $0.hasPrefix("# ") }) {
                let name = String(header.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                // Limit name length to prevent UI overflow
                if !name.isEmpty { return String(name.prefix(100)) }
            }
        }

        // Try package.json name field
        let packageJson = url.appendingPathComponent("package.json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: packageJson.path),
           let size = attrs[.size] as? Int, size <= maxDetectionFileSize,
           let data = try? Data(contentsOf: packageJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return String(name.prefix(100))
        }

        // Fall back to directory name
        return url.lastPathComponent
    }
}
