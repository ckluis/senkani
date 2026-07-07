import Foundation
import Combine

/// U.2b-2 GUI child a-2 — the SwiftUI-observable, `pane_id`-keyed surface
/// that bridges a `dispatch: .pane` run's lock/banner outcome back to the
/// visible `BrowserPaneView`.
///
/// **Why this type exists (the wiring gap it closes).** `BrowserPaneRunner`
/// is constructed FRESH per dispatch by `BrowserPaneRunnerFactory
/// .registerPaneRunner()`, so any lock state it kept on the runner instance
/// was discarded the moment the run returned — a view had no stable runner
/// to poll, and the double-dispatch guard checked a throwaway machine that
/// every fresh runner sees as `.unlocked` (so it could never actually catch
/// a second concurrent dispatch on the same pane). This store OUTLIVES the
/// per-dispatch runner because it is a process-global keyed by `pane_id`,
/// not owned by any runner instance — exactly the a-1 re-audit's ratified
/// option (b).
///
/// **Single transition authority.** `PaneLockStateMachine` REMAINS the sole
/// lock-transition authority. This store holds one `PaneLockStateMachine`
/// per pane and DELEGATES every transition to `machine.apply(_:)` — it does
/// NOT re-implement or shadow the transition table. On a rejected edge the
/// machine leaves its state unchanged and the store writes nothing back, so
/// the fail-closed guarantees (double-dispatch, dismiss-while-active) are
/// preserved verbatim.
///
/// **Schneier side-channel guard (structural).** The only refusal payload
/// this store can carry is `PaneRefusal` — a struct with EXACTLY two String
/// fields, `failingAxis` + `fixtureId`. The runner (in this library) writes
/// into the store; the view maps `PaneRefusal` → `RefusalBanner` for
/// display. Because the payload type structurally cannot hold the failed
/// assertion's captured output or the validation plan step list, no
/// side-channel can reach the banner even by accident. A structural test
/// asserts this whole file never names those forbidden fields.
///
/// **Threading.** The runner drives the store from a BACKGROUND thread
/// (`BrowserRunner.run` runs off-main); the view reads it on the main
/// actor. All state lives behind an `NSLock`, and `objectWillChange` is
/// fired on the main queue so SwiftUI invalidation is main-actor-correct.
/// The transition methods themselves are synchronous and return the
/// machine's `Result`, so the runner's double-dispatch guard can branch on
/// the outcome inline and pure-logic unit tests can assert the transition
/// table headlessly (no display, no running app).
public final class PaneDispatchStateStore: ObservableObject, @unchecked Sendable {

    /// Process-global store — one per app, mirroring `LivePaneRegistry
    /// .shared`. The runner writes into `.shared`; `BrowserPaneView`
    /// observes `.shared`. Tests construct their own instances via `init()`
    /// so they stay isolated from process state.
    public static let shared = PaneDispatchStateStore()

    /// The two safe identifiers a refusal may surface — nothing else. This
    /// is the Schneier guard expressed at the type level: the payload that
    /// crosses the runner → store → view boundary can carry ONLY the axis
    /// that failed and the opaque fixture id the refusal is scoped to.
    public struct PaneRefusal: Equatable, Sendable {
        /// The axis whose assertion failed (e.g. "security", "design").
        /// Names WHICH check failed, never WHAT the check saw.
        public let failingAxis: String
        /// The opaque fixture id the refusal is scoped to — an identifier
        /// the operator can look up out-of-band; carries no page content.
        public let fixtureId: String
        public init(failingAxis: String, fixtureId: String) {
            self.failingAxis = failingAxis
            self.fixtureId = fixtureId
        }
    }

    /// Per-pane observable state: the lock machine + the optional refusal
    /// payload. Invariant (enforced centrally in `apply`): `refusal` is
    /// non-nil IFF `lock.state == .refused`.
    public struct PaneState: Equatable, Sendable {
        public var lock: PaneLockStateMachine
        public var refusal: PaneRefusal?
        public init(lock: PaneLockStateMachine = PaneLockStateMachine(), refusal: PaneRefusal? = nil) {
            self.lock = lock
            self.refusal = refusal
        }
        /// True when the pane's URL bar + nav gestures should accept input.
        public var inputEnabled: Bool { lock.inputEnabled }
        /// True when the refusal banner overlay should be visible.
        public var bannerVisible: Bool { lock.bannerVisible }
    }

    /// The transition outcome the machine returns — surfaced so the runner
    /// can branch on the double-dispatch rejection inline and tests can
    /// assert rejected edges.
    public typealias TransitionResult = Result<PaneLockStateMachine.State, PaneLockStateMachine.TransitionError>

    // Combine invalidation publisher. Declared explicitly (rather than
    // relying on `@Published` synthesis) because state lives behind a lock,
    // not in a published property — `notifyChange()` sends this on main.
    public let objectWillChange = ObservableObjectPublisher()

    private let mutex = NSLock()
    private var states: [String: PaneState] = [:]

    public init() {}

    // MARK: - Reads

    /// Snapshot of a pane's dispatch state. An unseen `pane_id` reads as the
    /// default unlocked, no-banner state (never crashes / never fabricates a
    /// lock). Synchronous + thread-safe — the view calls this at render time.
    public func state(for paneId: String) -> PaneState {
        mutex.lock(); defer { mutex.unlock() }
        return states[paneId] ?? PaneState()
    }

    // MARK: - Transitions (each DELEGATES to PaneLockStateMachine)

    /// Lock the pane on dispatch start. Fail-closed: a second
    /// `.dispatchStarted` while this pane is already locked returns
    /// `.failure(.doubleDispatch)` and leaves state UNCHANGED — the runner
    /// turns that into a `validation_browser_pane_busy` refusal.
    @discardableResult
    public func dispatchStarted(paneId: String) -> TransitionResult {
        apply(paneId: paneId, event: .dispatchStarted, refusalPayload: nil)
    }

    /// Unlock the pane on a successful dispatch. Clears any refusal payload
    /// (the resulting state is `.unlocked`, so the invariant clears it).
    @discardableResult
    public func dispatchSucceeded(paneId: String) -> TransitionResult {
        apply(paneId: paneId, event: .dispatchSucceeded, refusalPayload: nil)
    }

    /// Refuse: surface the banner and stay locked. The payload is pinned to
    /// the two Schneier-safe identifiers by the `PaneRefusal` type.
    @discardableResult
    public func dispatchRefused(paneId: String, refusal: PaneRefusal) -> TransitionResult {
        apply(paneId: paneId, event: .dispatchRefused, refusalPayload: refusal)
    }

    /// Operator dismissed the banner — unlock and clear the payload.
    /// Fail-closed: a dismiss while a dispatch is still active (state
    /// `.locked`, no banner up) returns `.failure(.dismissWhileActive)` and
    /// leaves state unchanged.
    @discardableResult
    public func dismissBanner(paneId: String) -> TransitionResult {
        apply(paneId: paneId, event: .bannerDismissed, refusalPayload: nil)
    }

    // MARK: - Private

    /// Apply an event to a pane's machine and reconcile the banner payload.
    /// The lock transition is delegated wholesale to `PaneLockStateMachine
    /// .apply(_:)`; this method NEVER decides a transition itself. On a
    /// rejected edge it writes nothing back (fail-closed, matching the
    /// machine's no-mutate-on-reject contract).
    private func apply(paneId: String,
                       event: PaneLockStateMachine.Event,
                       refusalPayload: PaneRefusal?) -> TransitionResult {
        mutex.lock()
        var st = states[paneId] ?? PaneState()
        let result = st.lock.apply(event)   // ← sole transition authority
        guard case .success = result else {
            mutex.unlock()
            return result                     // rejected → state untouched
        }
        // Invariant: refusal is present IFF the resulting state is `.refused`.
        st.refusal = (st.lock.state == .refused) ? refusalPayload : nil
        states[paneId] = st
        mutex.unlock()
        notifyChange()
        return result
    }

    /// Fire SwiftUI invalidation on the main queue. The state mutation has
    /// already committed under the lock, so a re-render (which reads
    /// `state(for:)`) observes the new value. Off-main callers (the
    /// background-thread runner) hop to main; a main-thread caller (the
    /// view's dismiss handler) sends inline.
    private func notifyChange() {
        if Thread.isMainThread {
            objectWillChange.send()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.objectWillChange.send()
            }
        }
    }
}
