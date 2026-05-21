import Foundation

/// V.9a — PaneDiaryArtifactProvider.
///
/// Walks `<home>/.senkani/diaries/<workspaceSlug>/<paneSlug>.md` and
/// projects each diary file onto the ArtifactRecord shape. Tag
/// extraction = `{workspaceSlug, paneSlug}` (operator-supplied label
/// surface deferred to V.9b's gallery scope-groom).
///
/// Lineage: PaneDiaryStore does not currently record re-emission
/// history; `versions(of:)` returns an empty array. Pre-grooming
/// note #4 from the 2026-05-07 scope-groom round authorizes option
/// (b). Follow-up filed: `phase-v9a-followup-pane-diary-sprint-
/// review-lineage-recording-2026-05-21`.
///
/// Reads bypass `PaneDiaryStore.read(workspaceSlug:paneSlug:…)`
/// because that API requires explicit slug arguments — we parse the
/// slugs back out of the ArtifactID and read the file directly.
/// PaneDiaryStore remains the writer-of-record.
public struct PaneDiaryArtifactProvider: ArtifactSourceProvider {

    public let sourcePane: ArtifactSourcePane = .paneDiary
    public let home: String?

    public init(home: String? = nil) {
        self.home = home
    }

    public func list() -> [ArtifactRecord] {
        let base = (home ?? NSHomeDirectory()) + "/.senkani/diaries"
        let fm = FileManager.default
        guard let workspaceURLs = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var out: [ArtifactRecord] = []
        for wsURL in workspaceURLs.sorted(by: { $0.path < $1.path }) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: wsURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let workspace = wsURL.lastPathComponent

            guard let diaryURLs = try? fm.contentsOfDirectory(
                at: wsURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in diaryURLs.sorted(by: { $0.path < $1.path })
                where url.pathExtension == "md" {
                let pane = url.deletingPathExtension().lastPathComponent
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                let id = ArtifactID(
                    sourcePane: .paneDiary,
                    surfaceKey: workspace,
                    rowOrPath: pane
                )
                let record = ArtifactRecord(
                    id: id,
                    sourcePane: .paneDiary,
                    tags: [workspace, pane],
                    version: 1,
                    createdAt: mtime,
                    previousVersion: nil,
                    redactionMarker: nil
                )
                out.append(record)
            }
        }
        return out
    }

    public func read(_ id: ArtifactID) throws -> ArtifactBody {
        let parts = parse(id)
        guard parts.workspace.isEmpty == false, parts.pane.isEmpty == false else {
            throw ArtifactReadError.notFound(id: id)
        }
        let base = home ?? NSHomeDirectory()
        let path = "\(base)/.senkani/diaries/\(parts.workspace)/\(parts.pane).md"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            throw ArtifactReadError.notFound(id: id)
        }
        return ArtifactBody(bytes: data)
    }

    public func versions(of id: ArtifactID) -> [ArtifactRecord] {
        // PaneDiaryStore does not currently record re-emission history.
        // See class doc-comment + the follow-up backlog item.
        return []
    }

    private func parse(_ id: ArtifactID) -> (workspace: String, pane: String) {
        // ID shape: "paneDiary:<workspace>:<pane>"
        let parts = id.raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "paneDiary" else { return ("", "") }
        let workspace = String(parts[1])
        let pane = parts[2...].joined(separator: ":")
        return (workspace, pane)
    }
}
