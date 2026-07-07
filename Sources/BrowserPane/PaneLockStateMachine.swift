import Foundation

/// U.2b-2 GUI child a-1 — pure, unit-testable input-lock state machine for
/// the visible browser pane.
///
/// The problem it solves: while a `dispatch: .pane` validation run drives
/// the pane's live `WKWebView`, the operator must NOT be able to navigate
/// the pane out from under the run (typing a new URL, hitting back/forward,
/// reloading) — that would race the axis evaluation against a different
/// document than the one the audit row records. So the pane's URL bar and
/// navigation gestures are DISABLED for the duration of a dispatch and
/// re-enabled only when the run resolves.
///
/// This type owns ONLY the transition logic — it holds no AppKit/WebKit/
/// SwiftUI reference and imports Foundation alone, so it is exercised by
/// pure `swift test` unit tests with no display, no main actor, and no
/// live pane. The GUI half (`BrowserPaneView` disabling its controls,
/// `BrowserPaneRunner` driving the transitions around a live-pane run) is
/// wired against this machine; the real lock UX under a running app is the
/// honesty-bar deferral to sibling `phase-u2b-2-pane-gui-banner-lock-a-2`.
///
/// State model (three states, no hidden ones):
///   * `.unlocked`  — idle. URL bar + nav gestures enabled. No banner.
///   * `.locked`    — a dispatch is in flight. Input disabled. No banner.
///   * `.refused`   — the dispatch refused/failed; the refusal banner is
///                    shown and input stays disabled until the operator
///                    dismisses the banner (or a retry dispatch starts).
///
/// Unlock happens on SUCCESS (`.locked` → `.unlocked`) OR on banner
/// dismiss (`.refused` → `.unlocked`) — the two acceptance-named unlock
/// edges. Illegal edges (double-dispatch, dismiss during an active
/// dispatch) are rejected WITHOUT mutating state, so a mis-sequenced
/// caller cannot desync the lock.
public struct PaneLockStateMachine: Equatable, Sendable {

    public enum State: Equatable, Sendable {
        case unlocked
        case locked
        case refused
    }

    public enum Event: Equatable, Sendable {
        case dispatchStarted
        case dispatchSucceeded
        case dispatchRefused
        case bannerDismissed
    }

    /// Rejected transitions. The machine never mutates on a rejection —
    /// the caller's out-of-order event is a no-op against state.
    public enum TransitionError: Error, Equatable, Sendable {
        /// A second `.dispatchStarted` arrived while a dispatch was
        /// already in flight — the fail-closed guard against double
        /// dispatch on the same pane.
        case doubleDispatch
        /// A `.bannerDismissed` arrived while a dispatch was still active
        /// (state `.locked`, no banner yet) — there is nothing to dismiss.
        case dismissWhileActive
        /// Any other event not defined for the current state.
        case illegalTransition
    }

    public private(set) var state: State

    public init(state: State = .unlocked) {
        self.state = state
    }

    /// True when the URL bar + navigation gestures should accept input.
    /// The single source of truth `BrowserPaneView` binds its
    /// `.disabled(...)` modifiers to (inverted).
    public var inputEnabled: Bool { state == .unlocked }

    /// True when the refusal banner overlay should be visible.
    public var bannerVisible: Bool { state == .refused }

    /// Apply an event. On an accepted edge, mutates `state` and returns
    /// `.success(newState)`. On a rejected edge, leaves `state` UNCHANGED
    /// and returns `.failure(reason)`.
    @discardableResult
    public mutating func apply(_ event: Event) -> Result<State, TransitionError> {
        switch (state, event) {
        // Idle → dispatch begins.
        case (.unlocked, .dispatchStarted):
            state = .locked
            return .success(state)

        // Fail-closed: no double dispatch on the same pane.
        case (.locked, .dispatchStarted):
            return .failure(.doubleDispatch)

        // A retry dispatch may begin directly from a shown-banner state.
        case (.refused, .dispatchStarted):
            state = .locked
            return .success(state)

        // Unlock edge #1 — success.
        case (.locked, .dispatchSucceeded):
            state = .unlocked
            return .success(state)

        // Dispatch refused → show the banner, stay locked.
        case (.locked, .dispatchRefused):
            state = .refused
            return .success(state)

        // Fail-closed: cannot dismiss a banner mid-dispatch (none shown).
        case (.locked, .bannerDismissed):
            return .failure(.dismissWhileActive)

        // Unlock edge #2 — operator dismisses the refusal banner.
        case (.refused, .bannerDismissed):
            state = .unlocked
            return .success(state)

        default:
            return .failure(.illegalTransition)
        }
    }
}
