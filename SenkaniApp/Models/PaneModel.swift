import Foundation
import Core

/// The type of content a pane displays.
enum PaneType: String, CaseIterable {
    case terminal
    case analytics
    case markdownPreview
    case htmlPreview
    case skillLibrary
    case knowledgeBase
    case modelManager
    case scheduleManager
    case browser
    case diffViewer
    case logViewer
    case scratchpad
    case savingsTest
}

/// State of the process running in a terminal pane.
enum ProcessState: Equatable {
    case notStarted
    case running
    case exited(Int32)

    /// Whether the process is currently running.
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Per-pane feature toggle state. Mirrors SENKANI_* env vars.
/// Toggle changes are persisted to a per-pane config file so the hook script
/// picks them up on the next tool call without restarting the subprocess.
struct PaneFeatureConfig: Equatable {
    var filter: Bool = true
    var cache: Bool = true
    var secrets: Bool = true
    var indexer: Bool = true
    var terse: Bool = false

    /// Convert to environment variables for the subprocess.
    var environmentVars: [String: String] {
        var env: [String: String] = [:]
        env["SENKANI_FILTER"] = filter ? "on" : "off"
        env["SENKANI_CACHE"] = cache ? "on" : "off"
        env["SENKANI_SECRETS"] = secrets ? "on" : "off"
        env["SENKANI_INDEXER"] = indexer ? "on" : "off"
        env["SENKANI_TERSE"] = terse ? "on" : "off"
        return env
    }

    /// Write current toggle state to a per-pane env file.
    /// The hook script sources this file on each invocation, so toggles
    /// take effect on the next tool call without a subprocess restart.
    func persist(to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let content = environmentVars.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n") + "\n"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// All features off (passthrough mode).
    static let passthrough = PaneFeatureConfig(filter: false, cache: false, secrets: false, indexer: false, terse: false)
}

/// Model for a single pane in the workspace.
@Observable
final class PaneModel: Identifiable {
    let id = UUID()
    var title: String
    var paneType: PaneType
    var features: PaneFeatureConfig
    var metrics: PaneMetrics
    var processState: ProcessState
    var metricsFilePath: String
    var configFilePath: String
    var shellCommand: String
    /// Command to auto-run after the shell starts (e.g. "claude"). Empty = plain shell.
    var initialCommand: String
    /// Working directory for the terminal (project root path).
    var workingDirectory: String
    /// Claude session watcher (retained here so it lives as long as the pane).
    var claudeSessionWatcher: ClaudeSessionWatcher?
    /// File path for markdown/HTML preview panes.
    var previewFilePath: String
    /// User-resizable column width.
    var columnWidth: CGFloat = 300
    /// User-resizable height. nil = fill available height (default).
    var paneHeight: CGFloat? = nil

    init(title: String = "Terminal",
         paneType: PaneType = .terminal,
         features: PaneFeatureConfig = PaneFeatureConfig(),
         shellCommand: String = "/bin/zsh",
         initialCommand: String = "",
         workingDirectory: String = NSHomeDirectory(),
         previewFilePath: String = "") {
        let paneUUID = UUID().uuidString
        self.title = title
        self.paneType = paneType
        self.features = features
        self.metrics = PaneMetrics()
        self.processState = .notStarted
        self.metricsFilePath = "/tmp/senkani-pane-\(paneUUID).jsonl"
        self.configFilePath = NSHomeDirectory() + "/.senkani/panes/\(paneUUID).env"
        self.shellCommand = shellCommand
        self.initialCommand = initialCommand
        self.workingDirectory = workingDirectory
        self.previewFilePath = previewFilePath
        // Set default column width based on pane type
        switch paneType {
        case .skillLibrary:       self.columnWidth = 420
        case .knowledgeBase:      self.columnWidth = 400
        case .analytics:          self.columnWidth = 560
        case .browser:            self.columnWidth = 480
        case .markdownPreview:    self.columnWidth = 440
        case .htmlPreview:        self.columnWidth = 480
        case .diffViewer:         self.columnWidth = 440
        case .logViewer:          self.columnWidth = 340
        case .scratchpad:         self.columnWidth = 300
        case .terminal:           self.columnWidth = 300
        case .savingsTest:        self.columnWidth = 480
        default:                  self.columnWidth = 300
        }
        // Write initial toggle state so the hook script has it from the start
        features.persist(to: configFilePath)
    }

    /// Fallback metrics path derived from workingDirectory.
    /// Matches the path computed by MCPSession.fallbackMetricsPath() when
    /// SENKANI_METRICS_FILE is not in the MCP subprocess's environment.
    var fallbackMetricsPath: String {
        let components = workingDirectory.split(separator: "/")
        let name = components.suffix(2).joined(separator: "-")
        return NSHomeDirectory() + "/.senkani/metrics/" + name + ".jsonl"
    }

    // MARK: - Per-pane MCP config

    /// Path to the per-project .mcp.json that tells the MCP subprocess about
    /// SENKANI_METRICS_FILE (which it can't inherit from the terminal env).
    private var mcpJsonPath: String { workingDirectory + "/.mcp.json" }

    /// Write (or merge) a .mcp.json in the project directory so the MCP
    /// subprocess spawned by Claude Code gets SENKANI_METRICS_FILE in its env.
    func writeMCPConfig() {
        let path = mcpJsonPath
        let fm = FileManager.default

        // Read existing .mcp.json if present (user may have their own entries)
        var config: [String: Any] = [:]
        if let data = fm.contents(atPath: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }

        var mcpServers = config["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["senkani"] = [
            "command": AutoRegistration.resolveBinaryPath(),
            "args": ["--mcp-server"],
            "env": [
                "SENKANI_METRICS_FILE": metricsFilePath,
                "SENKANI_PROJECT_ROOT": workingDirectory,
                "SENKANI_PANE_ID": id.uuidString,
            ],
        ] as [String: Any]
        config["mcpServers"] = mcpServers

        guard let data = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }

        try? data.write(to: URL(fileURLWithPath: path))
    }

    /// Remove the senkani entry from .mcp.json (or delete the file if we're
    /// the only entry).
    func cleanupMCPConfig() {
        let path = mcpJsonPath
        let fm = FileManager.default

        guard let data = fm.contents(atPath: path),
              var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        guard var mcpServers = config["mcpServers"] as? [String: Any] else { return }
        mcpServers.removeValue(forKey: "senkani")

        if mcpServers.isEmpty {
            config.removeValue(forKey: "mcpServers")
        } else {
            config["mcpServers"] = mcpServers
        }

        // If config is now empty, delete the file entirely
        if config.isEmpty {
            try? fm.removeItem(atPath: path)
            return
        }

        if let updatedData = try? JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updatedData.write(to: URL(fileURLWithPath: path))
        }
    }
}
