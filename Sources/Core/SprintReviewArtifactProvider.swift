import Foundation
import SQLite3

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

    /// Database the lineage chain reads `sprint_review_snapshots`
    /// from. Tests inject a per-test DB; production defaults to the
    /// shared SessionDatabase.
    public let database: SessionDatabase

    public init(
        snapshotLoader: @Sendable @escaping () -> SprintReviewSnapshot = {
            SprintReviewViewModel.load()
        },
        database: SessionDatabase = .shared
    ) {
        self.snapshotLoader = snapshotLoader
        self.database = database
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

    /// Lineage chain for a SprintReview signal. Reads
    /// `sprint_review_snapshots WHERE kind=? AND row_id=? ORDER BY
    /// captured_at ASC` and projects each row to an ArtifactRecord
    /// with `version` = 1-based ordinal in the chain and
    /// `previousVersion` linked to the prior row. Empty array when
    /// the signal-id has never been observed by a pane-open event.
    public func versions(of id: ArtifactID) -> [ArtifactRecord] {
        let parts = parse(id)
        guard !parts.kind.isEmpty, !parts.rowId.isEmpty else { return [] }

        let rows: [(capturedAtMs: Int64, kind: String, rowId: String)] = database.queue.sync {
            guard let handle = database.db else { return [] }
            let sql = """
                SELECT captured_at, kind, row_id
                  FROM sprint_review_snapshots
                 WHERE kind = ? AND row_id = ?
                 ORDER BY captured_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (parts.kind as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            sqlite3_bind_text(stmt, 2, (parts.rowId as NSString).utf8String, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            var out: [(Int64, String, String)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let captured = sqlite3_column_int64(stmt, 0)
                let k = String(cString: sqlite3_column_text(stmt, 1))
                let rid = String(cString: sqlite3_column_text(stmt, 2))
                out.append((captured, k, rid))
            }
            return out
        }

        var chain: [ArtifactRecord] = []
        var prevID: ArtifactID? = nil
        for (i, r) in rows.enumerated() {
            let recordID = ArtifactID(
                sourcePane: .sprintReview,
                surfaceKey: r.kind,
                rowOrPath: r.rowId
            )
            chain.append(ArtifactRecord(
                id: recordID,
                sourcePane: .sprintReview,
                tags: [r.kind, r.rowId],
                version: i + 1,
                createdAt: Date(timeIntervalSince1970: Double(r.capturedAtMs) / 1000.0),
                previousVersion: prevID,
                redactionMarker: nil
            ))
            prevID = recordID
        }
        return chain
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
