import Foundation

/// Dispatch-queue marker for the dedicated serve-bridge executor. Set on the
/// dedicated executor's `queue` in `DedicatedThreadTaskExecutor.init`; read via
/// `ServeBridge.isRunningOnDedicatedExecutor()`. `DispatchSpecificKey` /
/// `setSpecific` / `getSpecific` are macOS-14-available, so this compiles at the
/// package floor. It is the deterministic detection seam for the phase-t1d-6
/// cooperative-pool deadlock regression test.
private let serveBridgeExecutorMarker = DispatchSpecificKey<Bool>()

/// Result holder for `ServeBridge.runBlocking` — top-level fileprivate generic
/// (a local generic class inside the generic func would be ill-formed). The
/// `@unchecked Sendable` is sound: the `DispatchSemaphore` enforces a strict
/// happens-before — the producing closure assigns `value` then `signal()`s;
/// the consumer `wait()`s then reads — so there is never a concurrent access.
private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// A `TaskExecutor` (SE-0417, macOS 15+) backed by a dedicated concurrent
/// `DispatchQueue` whose threads are NOT part of Swift Concurrency's
/// cooperative pool. Hosting the serve-bridge `Task` here is what lets it
/// START and run even when every cooperative-pool thread is parked in
/// `DispatchSemaphore.wait()` — the saturation that deadlocked a full
/// `swift test` (phase-t1d-6 P0).
@available(macOS 15.0, *)
final class DedicatedThreadTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue: DispatchQueue
    init(label: String) {
        self.queue = DispatchQueue(label: label, qos: .userInitiated, attributes: .concurrent)
        queue.setSpecific(key: serveBridgeExecutorMarker, value: true)
    }
    func enqueue(_ job: consuming ExecutorJob) {
        let unowned = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { unowned.runSynchronously(on: executor) }
    }
}

/// Shared sync↔async bridge for the OpenAI serve bridges (chat + embeddings),
/// which must call an async `ChatEngine`/`EmbeddingEngine` from the listener's
/// synchronous `(Data)->Data?` closure.
enum ServeBridge {
    /// Process-wide dedicated executor (macOS 15+). Created once; the bridges
    /// are low-frequency relative to GCD worker provisioning.
    @available(macOS 15.0, *)
    static let executor = DedicatedThreadTaskExecutor(label: "senkani.serve-bridge")

    /// True iff the caller is currently executing ON the dedicated serve-bridge
    /// executor's queue (the macOS-15 fix path), i.e. OFF Swift's cooperative
    /// pool. Returns false on a cooperative-pool thread and on the macOS-14
    /// floor (no dedicated executor). This is the deadlock-regression detection
    /// seam: `ServeBridgeDeadlockTests` asserts the bridge's awaited work runs
    /// here, which is exactly the property that prevents the phase-t1d-6
    /// cooperative-pool deadlock — proved deterministically, without racing
    /// global pool saturation.
    static func isRunningOnDedicatedExecutor() -> Bool {
        DispatchQueue.getSpecific(key: serveBridgeExecutorMarker) ?? false
    }

    /// Run `operation` to completion, blocking the calling thread until it
    /// returns. On macOS 15+ the work is hosted on `executor` (off the
    /// cooperative pool) so a saturated pool — every cooperative thread parked
    /// in this very `wait()` during `swift test` — cannot starve it.
    ///
    /// NOTE on scope of the guarantee: `executorPreference` keeps the
    /// nonisolated entry/exit hops on the dedicated executor. For the
    /// registration-suite stub engines (pure structs, no actor hop) the WHOLE
    /// `chat`/`embed` call stays on the dedicated executor — exactly the path
    /// that deadlocked. For the live MLX engine the awaited inference hops to
    /// actor `MLXChatEngine`/`MLXInferenceLock` and resumes on the default
    /// cooperative pool; that is fine because production callers block a
    /// GCD/NWListener thread (never a cooperative thread), so the cooperative
    /// pool is never saturated in production — the dedicated executor only has
    /// to let the bridge Task START.
    ///
    /// macOS-14 floor (`else`): SE-0417 is unavailable. Tests run on the
    /// macOS 15+ toolchain (they take the `if` branch), and production v14
    /// callers block a GCD/NWListener thread — never a cooperative thread —
    /// so this legacy cooperative-pool spawn cannot self-starve there. It is
    /// the pre-2026-06-01 behavior, preserved only for the v14 floor.
    ///
    /// Known, accepted risk (reviewer P2, accepted-as-documented): the dedicated
    /// executor's `.concurrent` queue could in principle over-provision GCD
    /// threads under high bridge concurrency, but serve-bridge calls are
    /// serialized by `MLXInferenceLock.shared` and are low-frequency, so they do
    /// not reach that regime in practice.
    static func runBlocking<T: Sendable>(_ operation: @Sendable @escaping () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        if #available(macOS 15.0, *) {
            Task(executorPreference: executor) {
                box.value = await operation()
                semaphore.signal()
            }
        } else {
            Task {
                box.value = await operation()
                semaphore.signal()
            }
        }
        semaphore.wait()
        // `operation` always assigns `box.value` before signalling, and the
        // semaphore makes that write happen-before this read.
        return box.value!
    }
}
