import Foundation

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
}

/// State of the process running in a terminal pane.
enum ProcessState {
    case notStarted
    case running
    case exited(Int32)
}

/// Per-pane feature toggle state. Mirrors SENKANI_* env vars.
/// Toggle changes are persisted to a per-pane config file so the hook script
/// picks them up on the next tool call without restarting the subprocess.
struct PaneFeatureConfig: Equatable {
    var filter: Bool = true
    var cache: Bool = true
    var secrets: Bool = true
    var indexer: Bool = true

    /// Convert to environment variables for the subprocess.
    var environmentVars: [String: String] {
        var env: [String: String] = [:]
        env["SENKANI_FILTER"] = filter ? "on" : "off"
        env["SENKANI_CACHE"] = cache ? "on" : "off"
        env["SENKANI_SECRETS"] = secrets ? "on" : "off"
        env["SENKANI_INDEXER"] = indexer ? "on" : "off"
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
    static let passthrough = PaneFeatureConfig(filter: false, cache: false, secrets: false, indexer: false)
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
    /// File path for markdown/HTML preview panes.
    var previewFilePath: String
    /// User-resizable column width. Defaults to 360 (theme default).
    var columnWidth: CGFloat = 360

    init(title: String = "Terminal",
         paneType: PaneType = .terminal,
         features: PaneFeatureConfig = PaneFeatureConfig(),
         shellCommand: String = "/bin/zsh",
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
        self.previewFilePath = previewFilePath
        // Write initial toggle state so the hook script has it from the start
        features.persist(to: configFilePath)
    }
}
