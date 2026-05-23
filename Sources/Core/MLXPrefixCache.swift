import Foundation

/// Per-session lifecycle wrap for an mlx-swift-lm KV prefix cache.
///
/// `MLXPrefixCache` mirrors the underlying cache's lifecycle as a five-
/// state machine — `warm` → `hit` | `coldMiss` → `evict` → `unload` —
/// firing each lifecycle hook exactly once per state transition. It is
/// the senkani-side observation surface for V.19a; downstream telemetry
/// (v19a-2 token-event columns, v19a-3 `cache_lifecycle` spans, v19a-4
/// dashboard tile) consumes these hooks.
///
/// ### Per-session only
///
/// One `MLXPrefixCache` wraps ONE session's KV cache. There is no
/// cross-session prefix dedup, no content-addressed block store, and
/// no hot-RAM/cold-SSD tier split — those remain explicitly deferred
/// to a follow-up V.19b. The public API enforces this: there is no
/// shared-state surface, no cross-cache identity binding, and no
/// content-addressed lookup.
///
/// ### Decoupled from MLX
///
/// This type deliberately does NOT import `MLXLMCommon`. It is a pure-
/// Swift state machine; the MLX-aware caller (an inference adapter in
/// `Sources/MCP/`) feeds cache observations in via `recordHit`,
/// `recordColdMiss`, `recordEvict`, `recordUnload`. This keeps
/// `Sources/Core/` free of Metal/MLX dependencies — same pattern as
/// `MLXInferenceLock`.
///
/// ### Hook execution context
///
/// Lifecycle hooks fire SYNCHRONOUSLY on the caller's thread, AFTER
/// the internal lock has been released, and OUTSIDE any
/// `MLXInferenceLock.shared.run { }` block. The hook callback path
/// MUST NOT issue Metal calls — `MLXInferenceLock` remains the Metal-
/// call serialization boundary. A negative test in
/// `MLXPrefixCacheTests` asserts that a hook invoked under an outer
/// `MLXInferenceLock.run` cannot reach Metal-call code by design.
public final class MLXPrefixCache: @unchecked Sendable {

    /// The five lifecycle states a session's KV cache progresses
    /// through. The state machine is monotone in the sense that
    /// `.unload` is terminal — no further transitions fire after
    /// unload.
    public enum LifecycleState: String, Sendable, CaseIterable {
        /// Cache constructed; not yet referenced by inference. Initial
        /// state on `init`.
        case warm
        /// Inference reused an existing prefix — first reference
        /// observed `offset > 0`.
        case hit
        /// Inference started fresh — first reference observed
        /// `offset == 0`.
        case coldMiss
        /// Cache trimmed below previous offset.
        case evict
        /// Cache released. Terminal — no further hooks fire.
        case unload
    }

    /// Hook signature. Carries the transitioned-to state, the cache's
    /// recorded offset at transition time, and the session identifier.
    /// Downstream telemetry needs all three to correlate cache events
    /// with the originating inference call.
    public typealias LifecycleHook = @Sendable (LifecycleState, Int, UUID) -> Void

    public let sessionID: UUID
    private var _state: LifecycleState
    private var _offset: Int
    private var hook: LifecycleHook?
    private let lock = NSLock()

    public var state: LifecycleState {
        lock.lock(); defer { lock.unlock() }
        return _state
    }

    public var offset: Int {
        lock.lock(); defer { lock.unlock() }
        return _offset
    }

    /// Construct a wrap for a session. Initial state is `.warm` and the
    /// warm hook fires synchronously during `init`. Callers that want
    /// to receive the warm event MUST pass `hook:` in the initializer —
    /// hooks attached via `attachHook` AFTER construction do not
    /// replay past transitions.
    public init(sessionID: UUID = UUID(), hook: LifecycleHook? = nil) {
        self.sessionID = sessionID
        self._state = .warm
        self._offset = 0
        self.hook = hook
        hook?(.warm, 0, sessionID)
    }

    /// Attach or replace the lifecycle hook. Past transitions are NOT
    /// replayed. Callers that need the warm event MUST pass the hook
    /// to `init`.
    public func attachHook(_ hook: @escaping LifecycleHook) {
        lock.lock(); defer { lock.unlock() }
        self.hook = hook
    }

    /// Record a prefix-cache hit: existing keys/values from a prior
    /// session were reattached, with `offset` tokens already in the
    /// cache. Caller-supplied offset MUST be positive; use
    /// `recordColdMiss()` for fresh sessions.
    ///
    /// Returns `true` if a state transition fired (and the hook was
    /// invoked); `false` if the state was already `.hit` and the
    /// offset unchanged, or the cache is already unloaded.
    @discardableResult
    public func recordHit(offset: Int) -> Bool {
        precondition(offset > 0,
            "recordHit requires offset > 0; use recordColdMiss for fresh sessions")
        return transition(to: .hit, newOffset: offset)
    }

    /// Record a cold cache miss: a fresh session with no prefix
    /// reuse. Offset stays at 0 at the time of the transition; the
    /// caller advances offset via `recordUpdate` as tokens accumulate.
    @discardableResult
    public func recordColdMiss() -> Bool {
        return transition(to: .coldMiss, newOffset: 0)
    }

    /// Record an in-place offset advance — token accumulation that
    /// does NOT change the lifecycle state. Used by callers to keep
    /// the wrap's offset accurate for telemetry without firing a hook
    /// on every generated token.
    public func recordUpdate(newOffset: Int) {
        lock.lock(); defer { lock.unlock() }
        if _state == .unload { return }
        _offset = newOffset
    }

    /// Record an eviction: cache trimmed to a lower offset (or zero).
    /// Fires the evict hook on transition into `.evict`.
    @discardableResult
    public func recordEvict(newOffset: Int) -> Bool {
        return transition(to: .evict, newOffset: newOffset)
    }

    /// Record release. After unload, no further transitions fire
    /// (every subsequent `record*` call is a no-op).
    @discardableResult
    public func recordUnload() -> Bool {
        return transition(to: .unload, newOffset: 0)
    }

    private func transition(to newState: LifecycleState, newOffset: Int) -> Bool {
        lock.lock()
        if _state == .unload {
            lock.unlock()
            return false
        }
        if _state == newState && _offset == newOffset {
            lock.unlock()
            return false
        }
        let capturedHook = hook
        let capturedSession = sessionID
        _state = newState
        _offset = newOffset
        lock.unlock()
        capturedHook?(newState, newOffset, capturedSession)
        return true
    }
}
