import Foundation

/// Public API for the V.6 annotation system. Forwards to the store;
/// kept as an extension to match the per-feature `+API.swift`
/// convention used elsewhere on `SessionDatabase`.
extension SessionDatabase {

    /// Insert one annotation row. Returns the new rowid, or -1 on
    /// failure. Caller validates the range invariant
    /// (`rangeEnd >= rangeStart`).
    @discardableResult
    public func recordAnnotation(_ annotation: Annotation) -> Int64 {
        return annotationStore.record(annotation)
    }

    /// Total annotation count. For tests + diagnostics.
    public func annotationCount() -> Int {
        return annotationStore.count()
    }

    /// All annotations on `(kind, id)`, newest first.
    public func annotations(kind: AnnotationTargetKind, id: String) -> [Annotation] {
        return annotationStore.byTarget(kind: kind, id: id)
    }

    /// Most recent N annotations across all targets.
    public func recentAnnotations(limit: Int = 50) -> [Annotation] {
        return annotationStore.recent(limit: limit)
    }

    /// Move every annotation pointing at `(kind, fromId)` to
    /// `(kind, toId)`. Wire into rename / fork flows so the lineage
    /// survives the artifact moving. Returns the number of rows
    /// updated.
    @discardableResult
    public func renameAnnotationTarget(
        kind: AnnotationTargetKind,
        from fromId: String,
        to toId: String
    ) -> Int {
        return annotationStore.renameTarget(kind: kind, fromId: fromId, toId: toId)
    }

    /// Per-(kind, target) verdict rollup — the analytic primitive
    /// CompoundLearning Analyze consumes.
    public func annotationVerdictRollup(
        targetKind: AnnotationTargetKind? = nil
    ) -> [AnnotationVerdictRollup] {
        return annotationStore.verdictRollup(targetKind: targetKind)
    }
}
