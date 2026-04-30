import Foundation

/// Public API for the V.12b annotation rate-cap log. Forwards to the
/// store; kept as an extension to match the per-feature `+API.swift`
/// convention used elsewhere on `SessionDatabase`.
extension SessionDatabase {

    /// Persist one rate-cap window summary. Called by
    /// `HookAnnotationFeed` when a window with at least one suppressed
    /// must-fix rolls over. Returns the new rowid or -1 on failure.
    @discardableResult
    public func recordAnnotationRateCap(_ row: AnnotationRateCapLogRow) -> Int64 {
        return annotationRateCapStore.record(row)
    }

    /// Recent rate-cap rows, newest first. For tests + the dashboard.
    public func recentAnnotationRateCaps(limit: Int = 100) -> [AnnotationRateCapLogRow] {
        return annotationRateCapStore.recent(limit: limit)
    }
}
