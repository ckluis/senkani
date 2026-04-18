import Testing
import Foundation
@testable import Core

// MLXInferenceLock is a serial FIFO lock + unload-handler registry.
// Tests construct a fresh instance (not `.shared`) so state is isolated.
// All tests drive the lock directly — none touch real MLX.

@Suite("MLXInferenceLock") struct MLXInferenceLockTests {

    /// Thread-safe order tracker used to observe entry/exit sequencing
    /// from concurrent `run` closures. Locking via `NSLock` because the
    /// closures execute on arbitrary tasks.
    final class OrderLog: @unchecked Sendable {
        private var events: [String] = []
        private let lock = NSLock()

        func append(_ event: String) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }

        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return events
        }
    }

    // MARK: - 1. Non-overlapping execution

    @Test func concurrentRunsDoNotOverlap() async throws {
        let lock = MLXInferenceLock()
        let log = OrderLog()
        let concurrent = 5

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<concurrent {
                group.addTask {
                    await lock.run {
                        log.append("enter-\(i)")
                        // Small async suspension to maximize interleave opportunity.
                        try? await Task.sleep(nanoseconds: 2_000_000)
                        log.append("exit-\(i)")
                    }
                }
            }
        }

        let events = log.snapshot()
        #expect(events.count == concurrent * 2)

        // Every enter must be immediately followed by its matching exit —
        // if two runs overlapped we'd see enter-A, enter-B, exit-A.
        for pair in stride(from: 0, to: events.count, by: 2) {
            let enter = events[pair]
            let exit = events[pair + 1]
            #expect(enter.hasPrefix("enter-"))
            #expect(exit.hasPrefix("exit-"))
            let enterId = enter.dropFirst("enter-".count)
            let exitId = exit.dropFirst("exit-".count)
            #expect(enterId == exitId, "Interleaved execution detected: \(events)")
        }
    }

    // MARK: - 2. FIFO ordering under contention

    @Test func queuedRunsExecuteInFIFOOrder() async throws {
        let lock = MLXInferenceLock()
        let log = OrderLog()

        // Hold the lock so subsequent submissions queue up.
        let gate = AsyncGate()
        let holder = Task {
            await lock.run {
                log.append("held")
                await gate.wait()
            }
        }

        // Wait until the first task actually holds the lock.
        while await lock.isHeld == false {
            try await Task.sleep(nanoseconds: 500_000)
        }

        // Submit three tasks in strict order; each records only once it starts.
        let t1 = Task { await lock.run { log.append("a") } }
        // Yield so the runtime appends waiter-1 before waiter-2.
        while await lock.queueDepth < 1 { try await Task.sleep(nanoseconds: 200_000) }
        let t2 = Task { await lock.run { log.append("b") } }
        while await lock.queueDepth < 2 { try await Task.sleep(nanoseconds: 200_000) }
        let t3 = Task { await lock.run { log.append("c") } }
        while await lock.queueDepth < 3 { try await Task.sleep(nanoseconds: 200_000) }

        // Release the holder — waiters should fire FIFO.
        await gate.open()
        await holder.value
        await t1.value; await t2.value; await t3.value

        #expect(log.snapshot() == ["held", "a", "b", "c"])
    }

    // MARK: - 3. Error in closure does not poison the lock

    @Test func errorInRunReleasesLockForNextCaller() async throws {
        let lock = MLXInferenceLock()

        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await lock.run { throw Boom() }
        }

        // Lock must be released; next caller executes without hanging.
        let ran = await lock.run { 42 }
        #expect(ran == 42)
        let held = await lock.isHeld
        let depth = await lock.queueDepth
        #expect(!held)
        #expect(depth == 0)
    }

    // MARK: - 4. Unload handlers fire on simulated memory warning

    @Test func registerUnloadHandlerAndFireOnWarning() async throws {
        let lock = MLXInferenceLock()
        let counter = Counter()

        await lock.registerUnloadHandler { await counter.increment() }
        await lock.registerUnloadHandler { await counter.increment() }

        let count = await lock.unloadHandlerCount
        #expect(count == 2)

        await lock.handleMemoryWarning()

        let value = await counter.value
        #expect(value == 2)
    }

    // MARK: - 5. clearUnloadHandlers leaves registry empty

    @Test func clearUnloadHandlersEmptiesRegistry() async throws {
        let lock = MLXInferenceLock()
        let counter = Counter()

        await lock.registerUnloadHandler { await counter.increment() }
        await lock.clearUnloadHandlers()

        let count = await lock.unloadHandlerCount
        #expect(count == 0)

        await lock.handleMemoryWarning()
        let value = await counter.value
        #expect(value == 0, "Handler must not fire after clear()")
    }

    // MARK: - 6. Memory monitor start/stop is idempotent and leaves state clean

    @Test func startMemoryMonitorIsIdempotentAndStopClears() async throws {
        let lock = MLXInferenceLock()

        await lock.startMemoryMonitor()
        await lock.startMemoryMonitor()  // second call is a no-op
        await lock.stopMemoryMonitor()

        // Re-start after stop must work.
        await lock.startMemoryMonitor()
        await lock.stopMemoryMonitor()

        // Registry state untouched by monitor lifecycle.
        let depth = await lock.unloadHandlerCount
        #expect(depth == 0)
    }

    // MARK: - 7. Queue depth shrinks as waiters drain

    @Test func queueDepthReflectsWaiters() async throws {
        let lock = MLXInferenceLock()
        let gate = AsyncGate()

        let holder = Task {
            await lock.run {
                await gate.wait()
            }
        }

        while await lock.isHeld == false {
            try await Task.sleep(nanoseconds: 200_000)
        }

        let w1 = Task { await lock.run { } }
        let w2 = Task { await lock.run { } }

        while await lock.queueDepth < 2 {
            try await Task.sleep(nanoseconds: 200_000)
        }

        let depthBefore = await lock.queueDepth
        #expect(depthBefore == 2)

        await gate.open()
        await holder.value
        await w1.value
        await w2.value

        let depthAfter = await lock.queueDepth
        let heldAfter = await lock.isHeld
        #expect(depthAfter == 0)
        #expect(!heldAfter)
    }
}

// MARK: - Test helpers

/// One-shot async gate — opens when `open()` is called; `wait()` suspends
/// until then. Built on CheckedContinuation so it integrates with the
/// existing actor/await machinery and doesn't need a timer loop.
actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters = []
        for w in pending { w.resume() }
    }
}

/// Actor-isolated counter for thread-safe accumulation in handlers.
actor Counter {
    private(set) var value: Int = 0
    func increment() { value += 1 }
}
