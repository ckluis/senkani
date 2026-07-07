import Foundation
import WebKit

/// U.2b-2 GUI child a-1 — fail-closed `pane_id` → live-pane resolution.
///
/// A `dispatch: .pane` validation run must drive the SAME live pane the
/// caller named. `BrowserPaneView` registers its live `WKWebView` here
/// keyed by `pane.id.uuidString` when it appears, and unregisters when it
/// closes. `BrowserPaneRunner`'s visible-pane mode resolves the requested
/// `pane_id` against this registry BEFORE evaluating any axis.
///
/// SECURITY-CRITICAL fail-closed contract (carried forward verbatim from
/// the 2026-06-26 re-audit's named wrong-pane risk):
///   * A `pane_id` that was never registered resolves to `.unknownPane`.
///   * A `pane_id` whose `WKWebView` has deallocated (the pane was closed)
///     resolves to `.closedPane` — the weak reference is nil.
///   * In NEITHER case does resolution fall back to a *different* live
///     pane. It refuses. `surface(paneId:)` returns nil unless resolution
///     is exactly `.resolved(<that same id>)`.
///   * A `nil` `pane_id` (the "most-recently-focused pane" convenience the
///     `Request.paneId` contract documents) resolves to the most recently
///     registered/focused LIVE pane, or `.noPanes` when none is live — it
///     is an explicit path, never a silent fallback from a failed specific
///     lookup.
///
/// The resolution logic operates on `AnyObject` weak references so the
/// fail-closed edges are exercised by pure `swift test` unit tests with a
/// dummy object standing in for a live `WKWebView` — no display, no
/// WebKit process. `BrowserPaneView` registers the real `WKWebView`; the
/// runtime binding to a rendering pane is the honesty-bar deferral to
/// sibling `phase-u2b-2-pane-gui-banner-lock-a-2`.
public final class LivePaneRegistry: @unchecked Sendable {

    /// Process-global registry — one visible-pane surface set per app.
    public static let shared = LivePaneRegistry()

    /// Outcome of resolving a requested `pane_id`. `Equatable` so unit
    /// tests assert the exact fail-closed branch.
    public enum Resolution: Equatable, Sendable {
        /// The requested (or most-recently-focused) pane is live.
        case resolved(paneId: String)
        /// A specific `pane_id` was requested that was never registered.
        case unknownPane(requested: String)
        /// A specific `pane_id` was registered but its surface has
        /// deallocated — the pane was closed (stale id).
        case closedPane(requested: String)
        /// `nil` was requested (most-recently-focused) but no live pane
        /// is registered.
        case noPanes
    }

    private final class WeakSurface {
        weak var object: AnyObject?
        init(_ object: AnyObject) { self.object = object }
    }

    private let lock = NSLock()
    private var panes: [String: WeakSurface] = [:]
    /// Registration/focus order — most-recently-touched id is last.
    private var order: [String] = []

    public init() {}

    /// Register (or replace) a live pane surface. Called by
    /// `BrowserPaneView.onAppear` with `pane.id.uuidString` + the live
    /// `WKWebView`. Idempotent per id; re-registering also marks the pane
    /// most-recent.
    public func register(paneId: String, surface: AnyObject) {
        lock.lock(); defer { lock.unlock() }
        panes[paneId] = WeakSurface(surface)
        order.removeAll { $0 == paneId }
        order.append(paneId)
    }

    /// Promote a live pane to most-recently-focused (drives the `nil`
    /// `pane_id` resolution). No-op for an unregistered id.
    public func markFocused(paneId: String) {
        lock.lock(); defer { lock.unlock() }
        guard panes[paneId] != nil else { return }
        order.removeAll { $0 == paneId }
        order.append(paneId)
    }

    /// Unregister a pane. Called by `BrowserPaneView.onDisappear`.
    public func unregister(paneId: String) {
        lock.lock(); defer { lock.unlock() }
        panes[paneId] = nil
        order.removeAll { $0 == paneId }
    }

    /// Fail-closed resolution. See the type doc for the contract.
    public func resolve(paneId: String?) -> Resolution {
        lock.lock(); defer { lock.unlock() }
        return _resolve(paneId)
    }

    /// The live surface for a resolved `pane_id`, or `nil`. Fail-closed:
    /// returns non-nil ONLY when resolution is `.resolved`, and returns
    /// exactly that pane's surface — never a different pane's.
    public func surface(paneId: String?) -> AnyObject? {
        lock.lock(); defer { lock.unlock() }
        guard case let .resolved(id) = _resolve(paneId) else { return nil }
        return panes[id]?.object
    }

    /// Count of live (non-deallocated) registered panes. Test/observability aid.
    public func liveCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return panes.values.reduce(0) { $0 + ($1.object == nil ? 0 : 1) }
    }

    // MARK: - Private (assumes `lock` held)

    private func _resolve(_ paneId: String?) -> Resolution {
        if let requested = paneId {
            guard let box = panes[requested] else {
                return .unknownPane(requested: requested)
            }
            guard box.object != nil else {
                return .closedPane(requested: requested)
            }
            return .resolved(paneId: requested)
        }
        // nil — most-recently-focused LIVE pane.
        for candidate in order.reversed() {
            if let box = panes[candidate], box.object != nil {
                return .resolved(paneId: candidate)
            }
        }
        return .noPanes
    }
}
