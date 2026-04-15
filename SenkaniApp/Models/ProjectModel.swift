import Foundation
import Core

/// Represents a project directory in the multi-repo workspace.
/// Each project owns workstreams (≥1, the default always exists), and each
/// workstream owns panes. This enables parallel git worktrees for feature
/// branches, hotfixes, and PR reviews.
///
/// SECURITY: Project paths are validated through ProjectSecurity on creation.
/// Security-scoped bookmarks are used for App Sandbox compatibility.
/// Path logging uses redacted paths to prevent credential leakage.
///
/// **Backwards compatibility:** The `panes` computed property delegates to
/// the active workstream's panes, so all existing code that reads `project.panes`
/// continues to work unchanged.
@Observable
final class ProjectModel: Identifiable {
    let id = UUID()
    var name: String

    /// Validated, symlink-resolved absolute path to project root.
    private(set) var path: String

    /// Security-scoped bookmark data for App Sandbox persistence.
    private(set) var bookmarkData: Data?

    // MARK: - Workstreams

    /// Workstreams in this project. Always ≥1 (default workstream).
    /// The invariant is enforced by init and removeWorkstream().
    var workstreams: [WorkstreamModel]

    /// Currently active workstream ID. nil = use default.
    var activeWorkstreamID: UUID?

    var isActive: Bool = false

    /// The active workstream (or default if none selected).
    var activeWorkstream: WorkstreamModel? {
        if let id = activeWorkstreamID {
            return workstreams.first { $0.id == id }
        }
        return workstreams.first { $0.isDefault } ?? workstreams.first
    }

    // MARK: - Compatibility Shims

    /// Panes from the active workstream. Backwards compatible with all existing code.
    var panes: [PaneModel] {
        get { activeWorkstream?.panes ?? [] }
        set { activeWorkstream?.panes = newValue }
    }

    /// Git branch from the active workstream.
    var gitBranch: String? {
        get { activeWorkstream?.branch }
        set { activeWorkstream?.branch = newValue }
    }

    // MARK: - Workstream Management

    /// Add a workstream to this project.
    func addWorkstream(_ workstream: WorkstreamModel) {
        workstreams.append(workstream)
        // Activate the new workstream
        for ws in workstreams { ws.isActive = false }
        workstream.isActive = true
        activeWorkstreamID = workstream.id
    }

    /// Remove a workstream. Returns false if it's the last one (invariant: ≥1).
    @discardableResult
    func removeWorkstream(id: UUID) -> Bool {
        guard workstreams.count > 1 else { return false }
        guard let idx = workstreams.firstIndex(where: { $0.id == id }) else { return false }
        let ws = workstreams[idx]
        guard !ws.isDefault else { return false }  // Can't remove default workstream
        workstreams.remove(at: idx)
        // If we removed the active workstream, switch to default
        if activeWorkstreamID == id {
            let def = workstreams.first { $0.isDefault } ?? workstreams[0]
            activeWorkstreamID = def.id
            def.isActive = true
        }
        return true
    }

    /// Switch to a workstream by ID.
    func switchWorkstream(to id: UUID) {
        for ws in workstreams { ws.isActive = (ws.id == id) }
        activeWorkstreamID = id
    }

    // MARK: - Git Branch Detection

    /// Detect the current git branch for this project's active workstream.
    func refreshGitBranch() {
        let dir = activeWorkstream?.effectiveRoot(projectPath: path) ?? path
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", dir, "rev-parse", "--abbrev-ref", "HEAD"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                activeWorkstream?.branch = branch
            }
        } catch {}
    }

    // MARK: - Metrics (aggregate across active workstream's panes)

    var totalSavedBytes: Int { panes.reduce(0) { $0 + $1.metrics.savedBytes } }
    var totalRawBytes: Int { panes.reduce(0) { $0 + $1.metrics.totalRawBytes } }

    var savingsPercent: Double {
        guard totalRawBytes > 0 else { return 0 }
        return Double(totalSavedBytes) / Double(totalRawBytes) * 100
    }

    var formattedSavings: String {
        let bytes = totalSavedBytes
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }

    var totalCommandCount: Int { panes.reduce(0) { $0 + $1.metrics.commandCount } }
    var runningPaneCount: Int { panes.filter { $0.processState.isRunning }.count }
    var totalSecretsCaught: Int { panes.reduce(0) { $0 + $1.metrics.secretsCaught } }
    var estimatedCostSaved: Double { ModelPricing.costSaved(bytes: totalSavedBytes) }
    var formattedCostSaved: String { ModelPricing.formatCost(estimatedCostSaved) }

    var redactedPath: String { ProjectSecurity.redactPath(path) }

    // MARK: - Initializers

    /// Internal initializer for trusted paths.
    /// Creates a default workstream automatically.
    init(name: String, trustedPath: String) {
        self.name = name
        self.path = trustedPath
        self.bookmarkData = nil
        let defaultWS = WorkstreamModel(name: "default", isDefault: true)
        defaultWS.isActive = true
        self.workstreams = [defaultWS]
    }

    /// Initializer with a pre-validated URL and optional bookmark.
    private init(name: String, validatedURL: URL, bookmark: Data?) {
        self.name = name
        self.path = validatedURL.path
        self.bookmarkData = bookmark
        let defaultWS = WorkstreamModel(name: "default", isDefault: true)
        defaultWS.isActive = true
        self.workstreams = [defaultWS]
    }

    /// Initializer for persistence restoration (with pre-built workstreams).
    init(name: String, trustedPath: String, bookmarkData: Data?, workstreams: [WorkstreamModel]) {
        self.name = name
        self.path = trustedPath
        self.bookmarkData = bookmarkData
        if workstreams.isEmpty {
            let defaultWS = WorkstreamModel(name: "default", isDefault: true)
            defaultWS.isActive = true
            self.workstreams = [defaultWS]
        } else {
            self.workstreams = workstreams
            // Ensure at least one is active
            if !workstreams.contains(where: { $0.isActive }) {
                (workstreams.first { $0.isDefault } ?? workstreams[0]).isActive = true
            }
        }
        self.activeWorkstreamID = self.workstreams.first(where: { $0.isActive })?.id
    }

    // MARK: - Factory Methods

    static func create(name: String? = nil, path: String) throws -> ProjectModel {
        let validatedURL = try ProjectSecurity.validateProjectPath(path)
        let bookmark = try? ProjectSecurity.createBookmark(for: validatedURL)
        let projectName = name ?? detectName(at: validatedURL)
        return ProjectModel(name: projectName, validatedURL: validatedURL, bookmark: bookmark)
    }

    static func restore(name: String, bookmarkData: Data) throws -> ProjectModel {
        let url = try ProjectSecurity.resolveBookmark(bookmarkData)
        let newBookmark = try? ProjectSecurity.createBookmark(for: url)
        return ProjectModel(name: name, validatedURL: url, bookmark: newBookmark ?? bookmarkData)
    }

    private static func detectName(at url: URL) -> String {
        let maxDetectionFileSize = 65_536

        let claudeMd = url.appendingPathComponent("CLAUDE.md")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: claudeMd.path),
           let size = attrs[.size] as? Int, size <= maxDetectionFileSize,
           let contents = try? String(contentsOf: claudeMd, encoding: .utf8) {
            let lines = contents.components(separatedBy: .newlines)
            if let header = lines.first(where: { $0.hasPrefix("# ") }) {
                let name = String(header.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return String(name.prefix(100)) }
            }
        }

        let packageJson = url.appendingPathComponent("package.json")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: packageJson.path),
           let size = attrs[.size] as? Int, size <= maxDetectionFileSize,
           let data = try? Data(contentsOf: packageJson),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return String(name.prefix(100))
        }

        return url.lastPathComponent
    }
}
