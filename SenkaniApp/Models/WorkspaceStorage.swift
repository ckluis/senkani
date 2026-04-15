import Foundation
import Core

// MARK: - Persisted Types (v2 — with workstream support)

struct PersistedWorkspace: Codable {
    var version: Int = 2
    var activeProjectIndex: Int?
    var activePaneIndex: Int?
    var projects: [PersistedProject]
}

struct PersistedProject: Codable {
    var name: String
    var bookmarkData: Data?
    var path: String
    /// v1 compatibility: panes at project level. Nil in v2 (panes live inside workstreams).
    var panes: [PersistedPane]?
    /// v2: workstreams containing panes. Nil in v1 files.
    var workstreams: [PersistedWorkstream]?
    /// v2: index of the active workstream.
    var activeWorkstreamIndex: Int?
}

/// v2: A workstream within a project.
struct PersistedWorkstream: Codable {
    var name: String
    var isDefault: Bool
    var branch: String?
    var worktreePath: String?
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

    // MARK: Save (always v2)

    static func save(_ workspace: WorkspaceModel) {
        let activeProjectIndex = workspace.projects.firstIndex { $0.id == workspace.activeProjectID }
        var activePaneIndex: Int?
        if let project = workspace.activeProject, let paneID = workspace.activePaneID {
            activePaneIndex = project.panes.firstIndex { $0.id == paneID }
        }

        let persisted = PersistedWorkspace(
            version: 2,
            activeProjectIndex: activeProjectIndex,
            activePaneIndex: activePaneIndex,
            projects: workspace.projects.map { project in
                let activeWSIndex = project.workstreams.firstIndex { $0.id == project.activeWorkstreamID }

                return PersistedProject(
                    name: project.name,
                    bookmarkData: project.bookmarkData,
                    path: project.path,
                    panes: nil,  // v2: panes live inside workstreams
                    workstreams: project.workstreams.map { ws in
                        PersistedWorkstream(
                            name: ws.name,
                            isDefault: ws.isDefault,
                            branch: ws.branch,
                            worktreePath: ws.worktreePath,
                            panes: ws.panes.map { persistPane($0) }
                        )
                    },
                    activeWorkstreamIndex: activeWSIndex
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

    // MARK: Load (v1 and v2 supported)

    static func load() -> WorkspaceModel? {
        guard let data = FileManager.default.contents(atPath: storagePath),
              let persisted = try? JSONDecoder().decode(PersistedWorkspace.self, from: data) else {
            return nil
        }

        let workspace = WorkspaceModel()

        for pp in persisted.projects {
            // Restore project from bookmark or fallback path
            let project: ProjectModel
            if let bookmark = pp.bookmarkData,
               let restored = try? ProjectModel.restore(name: pp.name, bookmarkData: bookmark) {
                project = restored
            } else if FileManager.default.isReadableFile(atPath: pp.path) {
                project = ProjectModel(name: pp.name, trustedPath: pp.path)
            } else {
                continue  // Path gone and no bookmark — skip
            }

            // Determine workstreams: v2 has workstreams[], v1 has panes[] at project level
            if let persistedWorkstreams = pp.workstreams, !persistedWorkstreams.isEmpty {
                // v2 format: restore workstreams with their panes
                var restoredWorkstreams: [WorkstreamModel] = []
                for pws in persistedWorkstreams {
                    let ws = WorkstreamModel(
                        name: pws.name,
                        isDefault: pws.isDefault,
                        branch: pws.branch,
                        worktreePath: pws.worktreePath
                    )
                    ws.panes = pws.panes.map { restorePane($0, workingDirectory: $0.workingDirectory) }
                    restoredWorkstreams.append(ws)
                }
                project.workstreams = restoredWorkstreams

                // Restore active workstream
                if let wsIdx = pp.activeWorkstreamIndex, wsIdx < restoredWorkstreams.count {
                    let activeWS = restoredWorkstreams[wsIdx]
                    activeWS.isActive = true
                    project.activeWorkstreamID = activeWS.id
                } else {
                    let def = restoredWorkstreams.first { $0.isDefault } ?? restoredWorkstreams[0]
                    def.isActive = true
                    project.activeWorkstreamID = def.id
                }
            } else if let v1Panes = pp.panes, !v1Panes.isEmpty {
                // v1 migration: wrap panes in default workstream
                let defaultWS = project.workstreams.first { $0.isDefault } ?? project.workstreams[0]
                defaultWS.panes = v1Panes.map { restorePane($0, workingDirectory: $0.workingDirectory) }
            }
            // else: no workstreams and no panes — project has empty default workstream (from init)

            workspace.projects.append(project)
        }

        // Restore active project
        if let idx = persisted.activeProjectIndex, idx < workspace.projects.count {
            let project = workspace.projects[idx]
            workspace.activeProjectID = project.id
            project.isActive = true

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

        return workspace.projects.isEmpty ? nil : workspace
    }

    // MARK: - Helpers

    private static func persistPane(_ pane: PaneModel) -> PersistedPane {
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

    private static func restorePane(_ ppane: PersistedPane, workingDirectory: String) -> PaneModel {
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
            workingDirectory: workingDirectory,
            previewFilePath: ppane.previewFilePath
        )
        pane.columnWidth = CGFloat(ppane.columnWidth)
        pane.paneHeight = ppane.paneHeight.map { CGFloat($0) }
        // Restore persisted metrics
        pane.metrics.totalRawBytes = ppane.totalRawBytes ?? 0
        pane.metrics.totalFilteredBytes = ppane.totalFilteredBytes ?? 0
        pane.metrics.commandCount = ppane.commandCount ?? 0
        pane.metrics.secretsCaught = ppane.secretsCaught ?? 0
        return pane
    }
}
