import Foundation

/// Pure display projection of a `PaneRefreshState`. The host (DashboardView)
/// reads `tone`, `iconSystemName`, `noticeText`, `errorText`, and
/// `accessibilityLabel` to render tile chrome. The error strip and notice
/// strip are *distinct* surfaces — error is a stronger red treatment that
/// signals "stale and broken", notice is a softer warning strip that means
/// "data is fresh but a partial result was used."
///
/// Putting this in Core (not the SwiftUI layer) keeps the rules unit-testable
/// without spinning up a view hierarchy. V.1 round 3 — see
/// `spec/app.md` "Live tile chrome" for the per-state contract.
public struct PaneRefreshTileDisplay: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        case normal
        case warning
        case error
    }

    public let tileTitle: String
    public let valueText: String
    public let tone: Tone
    public let iconSystemName: String?
    public let noticeText: String?
    public let errorText: String?
    public let accessibilityLabel: String

    public var hasNoticeStrip: Bool { noticeText != nil && tone == .warning }
    public var hasErrorStrip: Bool { errorText != nil && tone == .error }

    public init(tileTitle: String, state: PaneRefreshState, valueText: String) {
        self.tileTitle = tileTitle
        self.valueText = valueText

        // Error wins over notice — a tile that just failed shouldn't also
        // claim "partial". The scheduler clears notice on a successful refresh
        // already; we mirror the precedence here so the UI can never show
        // both strips at once.
        if let err = state.lastError {
            self.tone = .error
            self.iconSystemName = "exclamationmark.octagon.fill"
            self.errorText = err
            self.noticeText = nil
            self.accessibilityLabel = "\(tileTitle), error: \(err)"
        } else if let notice = state.notice {
            self.tone = .warning
            self.iconSystemName = "exclamationmark.triangle.fill"
            self.errorText = nil
            self.noticeText = notice
            self.accessibilityLabel = "\(tileTitle), partial: \(notice)"
        } else {
            self.tone = .normal
            self.iconSystemName = nil
            self.errorText = nil
            self.noticeText = nil
            let stateBlurb = state.contentAvailable ? valueText : "warming"
            self.accessibilityLabel = "\(tileTitle), \(stateBlurb)"
        }
    }
}

// MARK: - Fixture fetch helpers

/// Test-mode fetch that fails for the first `failuresBeforePartial` calls
/// and yields `.partial(notice:)` thereafter. Used by the V.1 round 3
/// fixture-injected upstream-failure path so the notice surface is
/// exercised end-to-end through `PaneRefreshCoordinator` and the
/// bounded worker pool.
///
/// The returned closure is `@Sendable` so it composes directly into a
/// `StatefulPaneRefresher.Fetch` slot.
public func paneRefreshFixtureFetch(
    failuresBeforePartial: Int,
    notice: String,
    failureMessage: String = "fixture failure"
) -> @Sendable (PaneRefreshContext) async -> PaneRefreshOutcome {
    // The counter mutates across calls; isolate it through an actor so
    // concurrent ticks can't race the increment.
    let counter = _FixtureCallCounter()
    return { _ in
        let n = await counter.next()
        if n <= failuresBeforePartial {
            return .failure(error: failureMessage)
        }
        return .partial(notice: notice)
    }
}

actor _FixtureCallCounter {
    private var n: Int = 0
    func next() -> Int {
        n += 1
        return n
    }
}
