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

            // Primary records correspond to unversioned `<pane>.md`
            // files. Versioned `<pane>.v<N>.md` siblings belong to
                // the chain returned by `versions(of:)` and are filtered
                // out here.
            for url in diaryURLs.sorted(by: { $0.path < $1.path })
                where url.pathExtension == "md" {
                let filename = url.lastPathComponent
                let stem = url.deletingPathExtension().lastPathComponent
                if isVersionedFilename(stem) { continue }
                let pane = stem
                _ = filename
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
                let id = ArtifactID(
                    sourcePane: .paneDiary,
                    surfaceKey: workspace,
                    rowOrPath: pane
                )
                // Primary record's version is `max(existing v<N>) + 1`
                // so the chain monotonically increases from v1 → … →
                // unversioned-as-latest.
                let latestVersionNumber = nextVersionFor(dir: wsURL, paneSlug: pane)
                let record = ArtifactRecord(
                    id: id,
                    sourcePane: .paneDiary,
                    tags: [workspace, pane],
                    version: latestVersionNumber,
                    createdAt: mtime,
                    previousVersion: previousVersionId(
                        workspace: workspace,
                        pane: pane,
                        currentVersion: latestVersionNumber,
                        wsURL: wsURL
                    ),
                    redactionMarker: nil
                )
                out.append(record)
            }
        }
        return out
    }

    /// `<pane>` is "versioned" when it ends in `.v<digits>` —
    /// matches `<paneSlug>.v<N>.md` rotated siblings.
    private func isVersionedFilename(_ stem: String) -> Bool {
        guard let dotIdx = stem.lastIndex(of: ".") else { return false }
        let suffix = stem[stem.index(after: dotIdx)...]
        guard suffix.first == "v" else { return false }
        let digits = suffix.dropFirst()
        return !digits.isEmpty && digits.allSatisfy { $0.isNumber }
    }

    /// `max(existing <pane>.v<N>.md siblings) + 1` (or 1 when none).
    /// Used by both `list()` (to label the unversioned as the latest)
    /// and `versions(of:)`.
    private func nextVersionFor(dir: URL, paneSlug: String) -> Int {
        let siblings = PaneDiaryStore.listVersionedSiblings(dir: dir, paneSlug: paneSlug)
        return (siblings.map { $0.version }.max() ?? 0) + 1
    }

    /// ArtifactID for `<pane>.v<currentVersion - 1>.md` if that file
    /// exists; otherwise nil.
    private func previousVersionId(
        workspace: String,
        pane: String,
        currentVersion: Int,
        wsURL: URL
    ) -> ArtifactID? {
        guard currentVersion > 1 else { return nil }
        let prevName = "\(pane).v\(currentVersion - 1).md"
        let prevPath = wsURL.appendingPathComponent(prevName).path
        guard FileManager.default.fileExists(atPath: prevPath) else { return nil }
        return ArtifactID(
            sourcePane: .paneDiary,
            surfaceKey: workspace,
            rowOrPath: "\(pane).v\(currentVersion - 1)"
        )
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

    /// Lineage chain for a PaneDiary slug pair. Resolves the
    /// versioned siblings (`<pane>.v<N>.md`) under the workspace
    /// directory and returns them sorted version ascending, with
    /// `previousVersion` populated for v2..vN. The unversioned
    /// `<pane>.md` is the chain's tail and carries version
    /// `max(N) + 1` so monotonicity holds. Empty chain when no
    /// diary file exists for the slug pair.
    public func versions(of id: ArtifactID) -> [ArtifactRecord] {
        let parts = parse(id)
        guard parts.workspace.isEmpty == false, parts.pane.isEmpty == false else {
            return []
        }
        let base = home ?? NSHomeDirectory()
        let wsURL = URL(fileURLWithPath: "\(base)/.senkani/diaries/\(parts.workspace)")
        let fm = FileManager.default
        let siblings = PaneDiaryStore.listVersionedSiblings(dir: wsURL, paneSlug: parts.pane)
        let primaryPath = "\(wsURL.path)/\(parts.pane).md"
        let primaryExists = fm.fileExists(atPath: primaryPath)
        if siblings.isEmpty && !primaryExists { return [] }

        var chain: [ArtifactRecord] = []
        var prevID: ArtifactID? = nil
        for entry in siblings {
            let recordID = ArtifactID(
                sourcePane: .paneDiary,
                surfaceKey: parts.workspace,
                rowOrPath: "\(parts.pane).v\(entry.version)"
            )
            chain.append(ArtifactRecord(
                id: recordID,
                sourcePane: .paneDiary,
                tags: [parts.workspace, parts.pane],
                version: entry.version,
                createdAt: entry.mtime,
                previousVersion: prevID,
                redactionMarker: nil
            ))
            prevID = recordID
        }

        if primaryExists {
            let attrs = try? fm.attributesOfItem(atPath: primaryPath)
            let mtime = (attrs?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let primaryVersion = (siblings.map { $0.version }.max() ?? 0) + 1
            let primaryID = ArtifactID(
                sourcePane: .paneDiary,
                surfaceKey: parts.workspace,
                rowOrPath: parts.pane
            )
            chain.append(ArtifactRecord(
                id: primaryID,
                sourcePane: .paneDiary,
                tags: [parts.workspace, parts.pane],
                version: primaryVersion,
                createdAt: mtime,
                previousVersion: prevID,
                redactionMarker: nil
            ))
        }

        return chain
    }

    private func parse(_ id: ArtifactID) -> (workspace: String, pane: String) {
        // ID shape: "paneDiary:<workspace>:<pane>".
        // The pane portion may carry a `.v<N>` suffix for a versioned
        // sibling (`paneDiary:proj:chat.v3`) — strip it so the chain
        // walk keys off the slug pair, not the specific revision.
        let parts = id.raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "paneDiary" else { return ("", "") }
        let workspace = String(parts[1])
        var pane = parts[2...].joined(separator: ":")
        if let dotIdx = pane.lastIndex(of: ".") {
            let suffix = pane[pane.index(after: dotIdx)...]
            if suffix.first == "v" {
                let digits = suffix.dropFirst()
                if !digits.isEmpty, digits.allSatisfy({ $0.isNumber }) {
                    pane = String(pane[..<dotIdx])
                }
            }
        }
        return (workspace, pane)
    }
}
