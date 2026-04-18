import Foundation

/// Global serialization primitive for on-device MLX inference.
///
/// MLX inference (vision + embedding + rationale rewriting) shares the
/// same Metal command queue and GPU memory pool. Running two inference
/// calls concurrently thrashes the pool and — on RAM-constrained
/// machines — triggers OOM-style stalls. This actor serializes all
/// inference work end-to-end across VisionEngine, EmbedEngine, and
/// GemmaInferenceAdapter.
///
/// Usage:
///
///     try await MLXInferenceLock.shared.run {
///         try await someModel.generate(...)
///     }
///
/// ### Memory pressure
///
/// On macOS, kernel memory-pressure transitions are observed via
/// `DispatchSource.makeMemoryPressureSource(eventMask: .warning)`. The
/// backlog item references `ProcessInfo.performMemoryWarning` — that
/// API is iOS-only. DispatchSource is the portable macOS equivalent
/// and fires on the same class of system events.
///
/// When a warning fires, every registered unload handler is invoked.
/// Each inference engine registers a handler that nils out its
/// ModelContainer; the next inference call re-loads via the engine's
/// existing RAM-aware fallback chain, which naturally steps down to a
/// smaller tier.
public actor MLXInferenceLock {

    public static let shared = MLXInferenceLock()

    // MARK: - Serialization state

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Unload handlers

    public typealias UnloadHandler = @Sendable () async -> Void
    private var unloadHandlers: [UnloadHandler] = []

    // MARK: - Memory pressure source

    private var memoryPressureSource: (any DispatchSourceMemoryPressure)?

    public init() {}

    // MARK: - Acquire / release

    /// Acquire the lock, suspending FIFO if it's already held.
    /// On return, the caller owns the lock and must call `release()`.
    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
        // On resume, ownership has been handed off from the previous holder.
        // `busy` stays true across the handoff.
    }

    /// Release the lock. If a waiter is queued, ownership transfers to it.
    func release() {
        precondition(busy, "MLXInferenceLock.release without matching acquire")
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            next.resume()
            // busy stays true — handed off directly
        } else {
            busy = false
        }
    }

    // MARK: - Run under lock

    /// Serialize an inference operation. Concurrent callers queue FIFO.
    /// The closure executes with exclusive access; errors propagate.
    public func run<T: Sendable>(
        _ op: @Sendable () async throws -> T
    ) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }

    // MARK: - Test hooks (actor-isolated reads)

    public var isHeld: Bool { busy }
    public var queueDepth: Int { waiters.count }
    public var unloadHandlerCount: Int { unloadHandlers.count }

    // MARK: - Unload handlers

    /// Register a handler invoked when a memory-pressure warning fires.
    /// Handlers should drop any loaded ModelContainer; the next inference
    /// call re-loads via the engine's RAM-aware fallback chain.
    public func registerUnloadHandler(_ handler: @escaping UnloadHandler) {
        unloadHandlers.append(handler)
    }

    /// Remove every registered unload handler. Test teardown hook.
    public func clearUnloadHandlers() {
        unloadHandlers = []
    }

    /// Invoke every registered unload handler serially. Exposed so tests
    /// can simulate a memory warning without wiring DispatchSource, and
    /// so the memory-pressure source can call it via an isolated hop.
    public func handleMemoryWarning() async {
        let handlers = unloadHandlers
        for h in handlers {
            await h()
        }
    }

    // MARK: - DispatchSource wiring

    /// Start watching for memory-pressure warnings. Idempotent — a
    /// second call is a no-op. Tests should NOT call this; use
    /// `handleMemoryWarning()` directly.
    public func startMemoryMonitor() {
        guard memoryPressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.handleMemoryWarning() }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Stop watching for memory-pressure warnings. Test teardown hook.
    public func stopMemoryMonitor() {
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
    }
}
