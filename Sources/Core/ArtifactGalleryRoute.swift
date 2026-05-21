import Foundation

// MARK: - V.9b-1 — ArtifactGalleryRouter
//
// Pure click-to-navigate routing for the ArtifactGalleryView pane.
// Lives in Core so SenkaniTests can assert the routing contract
// without standing up the SwiftUI surface.
//
// The view in SenkaniApp/Views/ArtifactGalleryView.swift consumes
// the returned `ArtifactNavRoute` and applies it against the actual
// WorkspaceModel / NSWorkspace surfaces — the router itself never
// touches those.
//
// Spec: spec/artifact_gallery.md, `## Gallery UI` section.

public enum ArtifactNavRoute: Equatable, Sendable {
    /// PaneDiary artifact. The view looks up an existing pane in
    /// `WorkspaceModel.activeProject.panes` whose `paneType.rawValue
    /// == paneSlug` and activates it; if none matches, the view
    /// calls `WorkspaceModel.addPane(type:)` to open one. The
    /// `workspaceSlug` is informational (gallery already filtered
    /// to the current project's artifacts via the FS-walk; the view
    /// asserts the active project's slug matches).
    case openOrFocusPaneDiary(workspaceSlug: String, paneSlug: String)

    /// SprintReview artifact. The view focuses an existing
    /// SprintReviewPane (creates one via `addPane(type: .sprintReview)`
    /// if not present). Scroll-to-row is honored when SprintReviewPane
    /// exposes a binding for it; V.9b-1 ships the focus path and
    /// leaves the scroll-target binding as a follow-up.
    case focusSprintReview(rowId: String, kind: String)

    /// Filesystem artifact. The view calls
    /// `NSWorkspace.shared.activateFileViewerSelecting(url)`.
    case revealInFinder(absolutePath: String)
}

public enum ArtifactGalleryRouter {

    /// Translate an `ArtifactRecord` into a navigation route. The
    /// `artifactsDirectory` is needed to resolve filesystem-pane
    /// records' absolute path; pass `FilesystemArtifactProvider
    /// .artifactsDirectory` from the view layer.
    ///
    /// Returns `nil` if the ID format is unparseable (malformed
    /// `raw`). Production-grade IDs are always well-formed; the nil
    /// return path exists for defensive callers (tests pass
    /// hand-crafted IDs).
    public static func route(
        for record: ArtifactRecord,
        artifactsDirectory: String
    ) -> ArtifactNavRoute? {
        let parts = record.id.raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }

        switch record.sourcePane {
        case .paneDiary:
            guard parts[0] == "paneDiary" else { return nil }
            let workspaceSlug = String(parts[1])
            let paneSlug = parts[2...].joined(separator: ":")
            return .openOrFocusPaneDiary(workspaceSlug: workspaceSlug, paneSlug: paneSlug)

        case .sprintReview:
            guard parts[0] == "sprintReview" else { return nil }
            let kind = String(parts[1])
            let rowId = parts[2...].joined(separator: ":")
            return .focusSprintReview(rowId: rowId, kind: kind)

        case .filesystem:
            guard parts[0] == "filesystem" else { return nil }
            let filename = parts[2...].joined(separator: ":")
            let path = "\(artifactsDirectory)/\(filename)"
            return .revealInFinder(absolutePath: path)
        }
    }

    // MARK: - Reveal-sheet canonical copy (V.9b-1)
    //
    // The detail pane's "Reveal body" confirmation sheet renders the
    // canonical string below — pinned here so tests assert the copy
    // verbatim. Norman P0 (V.9b-1 audit): redaction-reveal copy is a
    // user-facing contract; drift breaks Cavoukian-transparent intent.

    /// Canonical confirmation-sheet body copy. Substitutes
    /// `<sourcePane>` and `<hitCount>` literals.
    public static func revealSheetCopy(
        sourcePane: ArtifactSourcePane,
        hitCount: Int
    ) -> String {
        return "Reveal redacted body? Source: \(sourcePane.rawValue). Redaction marker hits: \(hitCount). This writes an artifact.secret.allow row to your audit chain."
    }
}
