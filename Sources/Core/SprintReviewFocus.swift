import Foundation
import Observation

/// V.9b-1 follow-up — focus-request surface for `SprintReviewPane`'s
/// scroll-to-row binding. Owned at app-process scope as a shared
/// instance; `ArtifactGalleryView`'s `.focusSprintReview(rowId:kind:)`
/// route handler pushes the rowId through `request(rowId:)`, and the
/// SprintReviewPane's body observes the request to drive
/// `ScrollViewReader.proxy.scrollTo(...)`.
///
/// Kept in Core so the request API and the resolver match-logic are
/// unit-testable from `SenkaniTests` without driving SwiftUI. The
/// SwiftUI integration (ScrollViewReader binding + `.onChange` to
/// fire scroll on `mutationStamp` and snapshot change) lives in
/// `SenkaniApp/Views/SprintReviewPane.swift`.
@MainActor
@Observable
public final class SprintReviewFocusRequest {
    /// Process-shared instance. The route handler and the pane both
    /// observe the same instance, so the wiring stays surgical
    /// (no environment plumbing through `PaneContainerView`).
    public static let shared = SprintReviewFocusRequest()

    /// Row id to scroll to on next observation. `nil` means no
    /// pending request.
    public var targetRowId: String?

    /// Monotonic counter incremented on every `request(rowId:)`.
    /// SwiftUI consumers observe `.onChange(of: mutationStamp)` so
    /// repeated requests with the same id still fire — the pane
    /// can refocus the same row when the operator double-clicks the
    /// same gallery artifact twice in a row.
    public var mutationStamp: Int = 0

    public init(targetRowId: String? = nil) {
        self.targetRowId = targetRowId
    }

    /// Push a new focus target. `mutationStamp` advances even when
    /// the new id matches the previous value, so idempotent re-
    /// issues drive a fresh scroll.
    public func request(rowId: String?) {
        targetRowId = rowId
        mutationStamp &+= 1
    }

    /// Clear the target after the pane has scrolled (or after the
    /// pane decides the target is unresolvable). Idempotent.
    public func consume() {
        targetRowId = nil
    }
}

/// V.9b-1 follow-up — pure match logic feeding
/// `SprintReviewFocusRequest` → SwiftUI scroll dispatch. Lives in
/// Core so `SenkaniTests` can exercise late-bind sequences and the
/// silent-no-op contract without SwiftUI.
public enum SprintReviewFocusResolver {
    /// Return the row id the pane should `scrollTo`, given a target
    /// request and a current snapshot. Returns `nil` when:
    /// (a) `target == nil`, or
    /// (b) no row in `snapshot.sections` (or staleness flag) has the
    ///     matching id — the pane is a silent no-op (no error, no
    ///     scroll).
    ///
    /// Returning the matched id (rather than a bool) preserves the
    /// late-bind sequencing contract: the pane calls the resolver
    /// twice (once on `mutationStamp` change, once on snapshot
    /// change); whichever call sees both the target AND the row
    /// fires the scroll.
    public static func matchedRow(
        target: String?,
        snapshot: SprintReviewSnapshot
    ) -> String? {
        guard let target else { return nil }
        for section in snapshot.sections {
            if section.rows.contains(where: { $0.id == target }) {
                return target
            }
        }
        if snapshot.stalenessFlags.contains(where: { $0.id == target }) {
            return target
        }
        return nil
    }
}
