import Foundation

/// V.9a — SprintReviewArtifactProvider.
///
/// Wraps `SprintReviewViewModel.load(...)` and projects each
/// `SprintReviewRow` onto the ArtifactRecord shape. Tag extraction
/// = `{row.kind.rawValue, row.id}`.
///
/// `read(_:)` returns the row's `title + subtitle` as utf8 bytes —
/// the row is a structured summary, not a free-form artifact body.
/// Callers driving the sprint-review pane go through
/// `SprintReviewViewModel` directly; this provider exists so the
/// gallery has a single uniform read API.
///
/// Lineage: SprintReviewViewModel does not currently record snapshot
/// history. `versions(of:)` returns an empty array. Pre-grooming
/// note #4 option (b). Follow-up filed:
/// `phase-v9a-followup-pane-diary-sprint-review-lineage-recording-
/// 2026-05-21`.
public struct SprintReviewArtifactProvider: ArtifactSourceProvider {

    public let sourcePane: ArtifactSourcePane = .sprintReview

    /// Loader seam — tests inject a fixture snapshot; production
    /// uses the default `SprintReviewViewModel.load()`.
    public let snapshotLoader: @Sendable () -> SprintReviewSnapshot

    public init(snapshotLoader: @Sendable @escaping () -> SprintReviewSnapshot = {
        SprintReviewViewModel.load()
    }) {
        self.snapshotLoader = snapshotLoader
    }

    public func list() -> [ArtifactRecord] {
        let snap = snapshotLoader()
        var out: [ArtifactRecord] = []
        for section in snap.sections {
            for row in section.rows {
                let id = ArtifactID(
                    sourcePane: .sprintReview,
                    surfaceKey: row.kind.rawValue,
                    rowOrPath: row.id
                )
                let record = ArtifactRecord(
                    id: id,
                    sourcePane: .sprintReview,
                    tags: [row.kind.rawValue, row.id],
                    version: 1,
                    createdAt: row.lastSeenAt,
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
        guard !parts.kind.isEmpty, !parts.rowId.isEmpty else {
            throw ArtifactReadError.notFound(id: id)
        }
        let snap = snapshotLoader()
        for section in snap.sections where section.kind.rawValue == parts.kind {
            if let row = section.rows.first(where: { $0.id == parts.rowId }) {
                let body = "\(row.title)\n\n\(row.subtitle)"
                return ArtifactBody(body)
            }
        }
        throw ArtifactReadError.notFound(id: id)
    }

    public func versions(of id: ArtifactID) -> [ArtifactRecord] {
        return []
    }

    private func parse(_ id: ArtifactID) -> (kind: String, rowId: String) {
        // ID shape: "sprintReview:<kind>:<rowId>"
        let parts = id.raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "sprintReview" else { return ("", "") }
        let kind = String(parts[1])
        let rowId = parts[2...].joined(separator: ":")
        return (kind, rowId)
    }
}
