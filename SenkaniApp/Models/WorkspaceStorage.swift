import Foundation
import Core

// MARK: - Persisted Types

struct PersistedWorkspace: Codable {
    var version: Int = 1
    var activeProjectIndex: Int?
    var activePaneIndex: Int?
    var projects: [PersistedProject]
}

struct PersistedProject: Codable {
    var name: String
    var bookmarkData: Data?
    var path: String
    var panes: [PersistedPane]
}

struct PersistedPane: Codable {
    var title: String
    var paneType: String
    var features: PersistedFeatures
    var shellCommand: String
    var initialCommand: String
    var workingDirectory: String
    var previewFilePath: String
    var columnWidth: Double
    var paneHeight: Double?
    // Metrics persistence — survives app restarts
    var totalRawBytes: Int?
    var totalFilteredBytes: Int?
    var commandCount: Int?
    var secretsCaught: Int?
}

struct PersistedFeatures: Codable {
    var filter: Bool
    var cache: Bool
    var secrets: Bool
    var indexer: Bool
    var terse: Bool
}

// MARK: - Storage

enum WorkspaceStorage {
    private static var storagePath: String {
        NSHomeDirectory() + "/.senkani/workspace.json"
    }

    // MARK: Save

    static func save(_ workspace: WorkspaceModel) {
        // Find active project/pane indices for restoration
        let activeProjectIndex = workspace.projects.firstIndex { $0.id == workspace.activeProjectID }
        var activePaneIndex: Int?
        if let project = workspace.activeProject, let paneID = workspace.activePaneID {
            activePaneIndex = project.panes.firstIndex { $0.id == paneID }
        }

        let persisted = PersistedWorkspace(
            version: 1,
            activeProjectIndex: activeProjectIndex,
            activePaneIndex: activePaneIndex,
            projects: workspace.projects.map { project in
                PersistedProject(
                    name: project.name,
                    bookmarkData: project.bookmarkData,
                    path: project.path,
                    panes: project.panes.map { pane in
                        PersistedPane(
                            title: pane.title,
                            paneType: pane.paneType.rawValue,
                            features: PersistedFeatures(
                                filter: pane.features.filter,
                                cache: pane.features.cache,
                                secrets: pane.features.secrets,
                                indexer: pane.features.indexer,
                                terse: pane.features.terse
                            ),
                            shellCommand: pane.shellCommand,
                            initialCommand: pane.initialCommand,
                            workingDirectory: pane.workingDirectory,
                            previewFilePath: pane.previewFilePath,
                            columnWidth: Double(pane.columnWidth),
                            paneHeight: pane.paneHeight.map { Double($0) },
                            totalRawBytes: pane.metrics.totalRawBytes,
                            totalFilteredBytes: pane.metrics.totalFilteredBytes,
                            commandCount: pane.metrics.commandCount,
                            secretsCaught: pane.metrics.secretsCaught
                        )
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(persisted) else { return }

        // Atomic write: temp file + rename
        let dir = (storagePath as NSString).deletingLastPathComponent
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }

        let url = URL(fileURLWithPath: storagePath)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".workspace.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")

        do {
            try data.write(to: tempURL)
            if fm.fileExists(atPath: storagePath) {
                _ = try fm.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fm.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fm.removeItem(at: tempURL)
        }
    }

    // MARK: Load

    static func load() -> WorkspaceModel? {
        guard let data = FileManager.default.contents(atPath: storagePath),
              let persisted = try? JSONDecoder().decode(PersistedWorkspace.self, from: data) else {
            return nil
        }

        let workspace = WorkspaceModel()

        for pp in persisted.projects {
            // Try to restore from bookmark first, fall back to trusted path
            let project: ProjectModel
            if let bookmark = pp.bookmarkData,
               let restored = try? ProjectModel.restore(name: pp.name, bookmarkData: bookmark) {
                project = restored
            } else if FileManager.default.isReadableFile(atPath: pp.path) {
                project = ProjectModel(name: pp.name, trustedPath: pp.path)
            } else {
                // Path gone and no bookmark — skip this project
                continue
            }

            // Restore panes
            for ppane in pp.panes {
                let paneType = PaneType(rawValue: ppane.paneType) ?? .terminal
                let features = PaneFeatureConfig(
                    filter: ppane.features.filter,
                    cache: ppane.features.cache,
                    secrets: ppane.features.secrets,
                    indexer: ppane.features.indexer,
                    terse: ppane.features.terse
                )
                let pane = PaneModel(
                    title: ppane.title,
                    paneType: paneType,
                    features: features,
                    shellCommand: ppane.shellCommand,
                    initialCommand: ppane.initialCommand,
                    workingDirectory: ppane.workingDirectory,
                    previewFilePath: ppane.previewFilePath
                )
                pane.columnWidth = CGFloat(ppane.columnWidth)
                pane.paneHeight = ppane.paneHeight.map { CGFloat($0) }
                // Restore persisted metrics
                pane.metrics.totalRawBytes = ppane.totalRawBytes ?? 0
                pane.metrics.totalFilteredBytes = ppane.totalFilteredBytes ?? 0
                pane.metrics.commandCount = ppane.commandCount ?? 0
                pane.metrics.secretsCaught = ppane.secretsCaught ?? 0
                project.panes.append(pane)
            }

            workspace.projects.append(project)
        }

        // Restore active project
        if let idx = persisted.activeProjectIndex, idx < workspace.projects.count {
            let project = workspace.projects[idx]
            workspace.activeProjectID = project.id
            project.isActive = true

            // Restore active pane
            if let paneIdx = persisted.activePaneIndex, paneIdx < project.panes.count {
                workspace.activePaneID = project.panes[paneIdx].id
            } else {
                workspace.activePaneID = project.panes.first?.id
            }
        } else if let first = workspace.projects.first {
            workspace.activeProjectID = first.id
            first.isActive = true
            workspace.activePaneID = first.panes.first?.id
        }

        // Return nil if nothing was restored (treat as fresh start)
        return workspace.projects.isEmpty ? nil : workspace
    }
}
