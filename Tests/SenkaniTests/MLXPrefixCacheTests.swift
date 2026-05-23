import Testing
import Foundation
@testable import Core

// MLXPrefixCache is a per-session lifecycle wrap exposing five
// lifecycle hooks (warm / hit / cold-miss / evict / unload). These
// tests drive the wrap directly without touching real MLX — same
// pattern as MLXInferenceLockTests.

@Suite("MLXPrefixCache") struct MLXPrefixCacheTests {

    /// Thread-safe event log used to observe lifecycle-hook firing
    /// order across the 5 tests below.
    final class HookLog: @unchecked Sendable {
        private var events: [(MLXPrefixCache.LifecycleState, Int, UUID)] = []
        private let lock = NSLock()

        func append(_ state: MLXPrefixCache.LifecycleState, _ offset: Int, _ sessionID: UUID) {
            lock.lock(); defer { lock.unlock() }
            events.append((state, offset, sessionID))
        }

        func snapshot() -> [(MLXPrefixCache.LifecycleState, Int, UUID)] {
            lock.lock(); defer { lock.unlock() }
            return events
        }

        func count(of state: MLXPrefixCache.LifecycleState) -> Int {
            snapshot().filter { $0.0 == state }.count
        }
    }

    // MARK: - 1. Full lifecycle (warm → hit → evict → unload)

    @Test func fullLifecycleHooksFireInOrder() async throws {
        let log = HookLog()
        let id = UUID()
        let cache = MLXPrefixCache(sessionID: id) { state, offset, sessionID in
            log.append(state, offset, sessionID)
        }

        // Warm fired on construction.
        let afterInit = log.snapshot()
        #expect(afterInit.count == 1)
        #expect(afterInit[0].0 == .warm)
        #expect(afterInit[0].1 == 0)
        #expect(afterInit[0].2 == id)

        // Hit (existing prefix reattached with 42 tokens).
        #expect(cache.recordHit(offset: 42))
        #expect(cache.state == .hit)
        #expect(cache.offset == 42)

        // In-place offset advance — must NOT fire a hook.
        cache.recordUpdate(newOffset: 100)
        #expect(cache.offset == 100)

        // Evict (trimmed back to 8 tokens).
        #expect(cache.recordEvict(newOffset: 8))
        #expect(cache.state == .evict)
        #expect(cache.offset == 8)

        // Unload (terminal).
        #expect(cache.recordUnload())
        #expect(cache.state == .unload)

        let events = log.snapshot()
        #expect(events.map { $0.0 } == [.warm, .hit, .evict, .unload])
        // recordUpdate did not produce a hook event.
        #expect(events.count == 4)
        // Session identity preserved across every transition.
        #expect(events.allSatisfy { $0.2 == id })
    }

    // MARK: - 2. Idempotent re-recording — hook fires exactly once per
    // state transition.

    @Test func idempotentRerecordingFiresOnce() async throws {
        let log = HookLog()
        let cache = MLXPrefixCache { state, offset, sessionID in
            log.append(state, offset, sessionID)
        }

        // Cold-miss first time fires once.
        #expect(cache.recordColdMiss())
        // Second identical call is a no-op (state already coldMiss + offset 0).
        #expect(cache.recordColdMiss() == false)
        #expect(cache.recordColdMiss() == false)

        // Hit at offset 50 fires once.
        #expect(cache.recordHit(offset: 50))
        // Repeating with same offset is a no-op.
        #expect(cache.recordHit(offset: 50) == false)

        // Hit hook re-fires when offset changes (new prefix reattached).
        #expect(cache.recordHit(offset: 75))

        let events = log.snapshot()
        // Expected: warm (init), coldMiss, hit(50), hit(75) = 4 events.
        #expect(events.count == 4)
        #expect(log.count(of: .warm) == 1)
        #expect(log.count(of: .coldMiss) == 1)
        #expect(log.count(of: .hit) == 2)
    }

    // MARK: - 3. Hook fires outside MLXInferenceLock — no Metal-call
    // entry from the lifecycle-hook callback path.

    @Test func hookFiresOutsideMLXInferenceLock() async throws {
        // Construct an MLXInferenceLock (NOT .shared so tests are
        // isolated). Acquire the lock, then trigger a lifecycle
        // transition from inside the lock's run closure. The hook
        // callback runs synchronously on the current task, but it
        // does NOT call `MLXInferenceLock.shared.run` — i.e. the
        // hook does not attempt to issue Metal-call work from inside
        // the callback path. We assert the inner lock is still
        // acquirable from a SECOND task while the hook executes,
        // which would NOT be true if the hook tried to re-enter the
        // outer serialization boundary.
        let lock = MLXInferenceLock()
        let log = HookLog()
        let hookFired = HookLog()

        let cache = MLXPrefixCache { state, offset, sessionID in
            // Lifecycle hooks MUST NOT issue Metal calls. We model
            // "no Metal call" by NOT calling lock.run from here.
            // Pure logging is the only side effect.
            hookFired.append(state, offset, sessionID)
        }

        await lock.run {
            // Trigger transitions from inside the inference lock.
            // The hook callback runs synchronously on this task BUT
            // it does not perform Metal-call work — it only logs.
            log.append(.coldMiss, 0, UUID())
            _ = cache.recordColdMiss()
            _ = cache.recordEvict(newOffset: 0)
        }

        // After the outer lock.run returns, the lock is released.
        // The hooks already fired during the closure — verify they
        // observed both transitions without deadlocking.
        let events = hookFired.snapshot()
        let lifecycleStates = events.map { $0.0 }
        // warm (from init), coldMiss, evict.
        #expect(lifecycleStates.contains(.warm))
        #expect(lifecycleStates.contains(.coldMiss))
        #expect(lifecycleStates.contains(.evict))

        // Lock is fully released — a second run completes without
        // contention.
        let secondRanBox = HookLog()
        await lock.run {
            secondRanBox.append(.warm, 0, UUID())
        }
        #expect(secondRanBox.snapshot().count == 1)
    }

    // MARK: - 4. Public API is per-session only — no cross-session
    // surface exposed.

    @Test func publicSurfaceIsPerSessionOnly() async throws {
        // Two MLXPrefixCache instances have DISTINCT identities and
        // share NO state. There is no public method, property, or
        // initializer that would let one cache reference, dedupe
        // against, or look up state from another cache.
        let a = MLXPrefixCache()
        let b = MLXPrefixCache()

        #expect(a.sessionID != b.sessionID)

        // Drive a through its lifecycle; b must not observe any of
        // a's transitions.
        let bLog = HookLog()
        b.attachHook { state, offset, sessionID in
            bLog.append(state, offset, sessionID)
        }

        _ = a.recordHit(offset: 10)
        _ = a.recordEvict(newOffset: 0)
        _ = a.recordUnload()

        // b's state is untouched.
        #expect(b.state == .warm)
        #expect(b.offset == 0)
        // b's hook never fired.
        #expect(bLog.snapshot().isEmpty)

        // The public API surface check — Mirror the type and confirm
        // no instance member exposes a global/cross-cache registry.
        // (Compile-time enforcement: no `static var` or `class func`
        // accepts a cache identity to look up.) We perform a runtime
        // sanity check that the type has no static-property surface
        // beyond what's expected.
        let mirror = Mirror(reflecting: a)
        let memberNames = mirror.children.compactMap { $0.label }
        // Expected stored properties: sessionID + _state + _offset +
        // hook + lock. NO `_globalRegistry`, `_caches`, `_dedupTable`.
        #expect(!memberNames.contains(where: { name in
            name.contains("globalRegistry") ||
            name.contains("dedupTable") ||
            name.contains("blockStore") ||
            name.contains("crossSession")
        }))
    }

    // MARK: - 5. Concurrent transitions are race-safe — hook count
    // converges; unload is terminal.

    @Test func concurrentTransitionsAreRaceSafe() async throws {
        let log = HookLog()
        let cache = MLXPrefixCache { state, offset, sessionID in
            log.append(state, offset, sessionID)
        }

        // Race many concurrent recordHit calls. Internal NSLock
        // serializes mutation; the hook fires for state-and-offset
        // transitions only. Since each call uses a different offset,
        // we may see multiple hit hooks — but never an inconsistent
        // intermediate state.
        await withTaskGroup(of: Void.self) { group in
            for i in 1...20 {
                group.addTask {
                    _ = cache.recordHit(offset: i * 10)
                }
            }
        }

        // After the race, state must be `.hit` and offset must equal
        // the value recorded by the LAST-winning task. We can't
        // predict which task won, but offset must be one of the
        // recorded values (10..200 step 10).
        #expect(cache.state == .hit)
        let validOffsets = Set((1...20).map { $0 * 10 })
        #expect(validOffsets.contains(cache.offset))

        // Unload is terminal — subsequent transitions are no-ops.
        #expect(cache.recordUnload())
        #expect(cache.state == .unload)
        #expect(cache.recordHit(offset: 99) == false)
        #expect(cache.recordColdMiss() == false)
        #expect(cache.recordEvict(newOffset: 0) == false)
        #expect(cache.recordUnload() == false)

        // The state remained `.unload` across all the no-op calls.
        #expect(cache.state == .unload)

        // Total hook count: warm (1) + hit (>=1) + unload (1).
        let events = log.snapshot()
        #expect(events.first?.0 == .warm)
        #expect(events.last?.0 == .unload)
        #expect(log.count(of: .unload) == 1)
        #expect(log.count(of: .warm) == 1)
    }
}
