import Testing
import Foundation
@testable import Core
import MCPServer

/// Phase hook-relay a-1 — regression-lock the async decoupling of
/// `HookRouter.handle()`'s bookkeeping side effects, plus pin the
/// trust-flag persistence move off the synchronous response path.
///
/// Before this suite, NOTHING asserted the non-blocking contract of the
/// three already-shipped async paths (`recordHookEvent`,
/// `AutoValidateQueue.enqueue`, `KBObserver.observeHookEvent`), so a
/// future edit could silently reintroduce an inline synchronous DB/actor
/// hit on the hook response path with no alarm. These tests fail loudly
/// if that happens.
///
/// Determinism strategy. `SessionDatabase.shared.queue` is a single
/// serial `DispatchQueue`. Both `recordHookEvent`'s write and
/// `AutoValidateQueue.enqueue`'s audit-event writes funnel through it.
/// Occupying that queue with a barrier and then asserting `handle()`
/// returns while the queue is still blocked proves the side effect is
/// dispatched (async), not run inline: a revert to a synchronous inline
/// write would block `handle()` behind the barrier and time the wait out.
/// The trust-flag tests use an injected sink (session-scoped so peer
/// suites' traffic passes through untouched) instead of the shared queue.
///
/// CI runs `tools/test-safe.sh` with `SWT_NO_PARALLEL=1`, so these run
/// serially — no peer contends the shared detector / queue / seams.
@Suite("HookRouter — non-blocking bookkeeping (hook-relay a-1)", .serialized)
struct HookRouterNonBlockingBookkeepingTests {

    // MARK: - Helpers

    private static func makeEvent(
        toolName: String,
        toolInput: [String: Any],
        eventName: String,
        sessionId: String,
        cwd: String? = nil,
        paneId: String? = nil
    ) -> Data {
        var event: [String: Any] = [
            "tool_name": toolName,
            "hook_event_name": eventName,
            "session_id": sessionId,
            "tool_input": toolInput,
        ]
        if let cwd { event["cwd"] = cwd }
        if let paneId { event["pane_id"] = paneId }
        return try! JSONSerialization.data(withJSONObject: event)
    }

    /// Occupy the shared serial DB queue until `release` is signalled.
    /// Returns once the barrier block is confirmed running (so the queue
    /// is genuinely blocked before the caller proceeds).
    private static func occupySharedDBQueue(release: DispatchSemaphore) {
        let running = DispatchSemaphore(value: 0)
        SessionDatabase.shared.queue.async {
            running.signal()
            release.wait()
        }
        running.wait()
    }

    /// Run `block` on a DEDICATED thread; return `.success` iff it returned
    /// within `seconds`. A blocking (inline-sync) path leaves it stuck and
    /// this times out.
    ///
    /// A dedicated `Thread` (not `DispatchQueue.global()`) is deliberate:
    /// peer suites that fire flag-producing events with the production
    /// `trustFlagSink` leave detached persistence Tasks that block on
    /// `SessionDatabase.shared.queue.sync`; if the Dispatch global pool is
    /// under pressure a `global().async` block might not be scheduled
    /// promptly — a false timeout. A dedicated thread is immune to that
    /// pool pressure, so a timeout here means `block` itself blocked.
    private static func returnsWithin(_ seconds: Double, _ block: @escaping @Sendable () -> Void) -> DispatchTimeoutResult {
        let done = DispatchSemaphore(value: 0)
        let worker = Thread {
            block()
            done.signal()
        }
        worker.stackSize = 1 << 20
        worker.start()
        return done.wait(timeout: .now() + seconds)
    }

    /// Convenience: run `HookRouter.handle` under `returnsWithin`.
    private static func handleReturns(_ eventJSON: Data, within seconds: Double) -> DispatchTimeoutResult {
        returnsWithin(seconds) { _ = HookRouter.handle(eventJSON: eventJSON) }
    }

    // MARK: - 1. recordHookEvent (bullet 1)

    @Test("recordHookEvent's DB persistence dispatches on the background queue, not inline — handle()'s inline call to it cannot block the response path")
    func recordHookEventDoesNotBlockHandle() {
        // `handle()` calls `SessionDatabase.shared.recordHookEvent(...)`
        // INLINE on its response path (HookRouter.swift ~:420), relying on
        // recordHookEvent's write being internally async
        // (`TokenEventStore.recordTokenEvent` → `queue.async`). So the
        // load-bearing non-blocking property lives INSIDE recordHookEvent,
        // and the tight, deterministic probe is to call it directly with
        // the shared serial DB queue occupied: an async dispatch enqueues
        // behind the barrier and returns immediately; a regression to an
        // inline `queue.sync` write blocks behind the barrier and times out.
        //
        // Calling recordHookEvent directly (NOT through `handle()`) is
        // deliberate: `handle()` holds `HookSeamLock` for its whole body and
        // performs synchronous shared-queue DB reads under it, so occupying
        // the queue AND routing through `handle()` can deadlock against any
        // concurrent/straggler `handle()` that is mid-body holding the lock.
        // The direct call touches no seam lock, so it is deadlock-free while
        // still biting the exact regression the acceptance criterion names.
        SessionDatabase.shared.flushWrites() // drain prior work

        let release = DispatchSemaphore(value: 0)
        Self.occupySharedDBQueue(release: release)
        defer { release.signal() } // always free the queue, even on failure

        let sid = "sid-a1-recordhookevent-\(UUID().uuidString)"
        #expect(
            Self.returnsWithin(5, {
                SessionDatabase.shared.recordHookEvent(
                    sessionId: sid,
                    toolName: "Bash",
                    eventType: "PostToolUse",
                    projectRoot: "/tmp"
                )
            }) == .success,
            "recordHookEvent blocked on the occupied DB queue — its persistence is running INLINE (queue.sync) instead of dispatching async (regression: handle()'s inline call would then block the response path)"
        )
    }

    // MARK: - 2. AutoValidateQueue.enqueue (bullet 2)

    @Test("handle() does not block on AutoValidateQueue.enqueue — the PostToolUse Edit path returns before a deliberately-slow injected enqueue seam completes")
    func autoValidateEnqueueDoesNotBlockHandle() {
        // NOTE on mechanism. `AutoValidateQueue.enqueue`'s own body does no
        // synchronous blocking I/O — its only DB touch, `record(...)`, is
        // `SessionDatabase.recordEvent` → `queue.async` (fire-and-forget).
        // So occupying the shared DB queue cannot detect an inline enqueue:
        // an inline `await enqueue(...)` returns just as fast as a
        // Task-wrapped one. The deterministic biting probe is the injected
        // `autoValidateEnqueue` seam: park it, and only a response path that
        // awaits the enqueue INLINE (drops the `Task {}`) stalls behind it.
        let mySid = "sid-a1-autovalidate-\(UUID().uuidString)"
        let original = HookRouter.autoValidateEnqueue
        let seamEntered = DispatchSemaphore(value: 0)
        let releaseSeam = DispatchSemaphore(value: 0)

        // Session-scoped: only OUR event drives the blocking seam; every
        // peer suite's PostToolUse traffic passes through to the real
        // enqueue untouched. Guard the swap with HookSeamLock per the
        // seam-override discipline.
        HookSeamLock.withLock {
            HookRouter.autoValidateEnqueue = { path, sessionId, projectRoot in
                if sessionId == mySid {
                    seamEntered.signal()
                    // Park until released — models a slow enqueue body. A
                    // regression that awaits this inline on the response
                    // path would stall handle() right here.
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        DispatchQueue.global().async {
                            releaseSeam.wait()
                            cont.resume()
                        }
                    }
                } else {
                    await original(path, sessionId, projectRoot)
                }
            }
        }
        defer {
            releaseSeam.signal() // unpark the seam
            HookSeamLock.withLock { HookRouter.autoValidateEnqueue = original }
        }

        // A PostToolUse Edit event drives `handlePostEditWrite` → the
        // fire-and-forget `Task { await autoValidateEnqueue(...) }`.
        let evt = Self.makeEvent(
            toolName: "Edit",
            toolInput: ["file_path": "/tmp/senkani-a1-nonblock-\(UUID().uuidString).swift"],
            eventName: "PostToolUse",
            sessionId: mySid,
            cwd: "/tmp"
        )

        #expect(
            Self.handleReturns(evt, within: 5) == .success,
            "handle() blocked — AutoValidateQueue.enqueue is running INLINE on the response path instead of a detached Task"
        )
        // The enqueue seam WAS invoked (from the fire-and-forget Task),
        // proving the enqueue happens, just off the response path.
        #expect(
            seamEntered.wait(timeout: .now() + 5) == .success,
            "the auto-validate enqueue seam never fired — expected the PostToolUse Edit to enqueue off the response path"
        )
    }

    // MARK: - 3. KBObserver.observeHookEvent (bullet 3)

    @Test("KBObserver.observeHookEvent returns synchronously — registry+actor work runs in a detached Task, not inline")
    func kbObserverDefersRegistryWork() {
        // Empty text → cheap early return, no Task spawned. Must not hang.
        KBObserver.observeHookEvent(toolName: "Bash", toolInput: [:])

        // Non-empty text spawns `Task.detached`. `observeHookEvent` is a
        // synchronous `-> Void` function, so the `await KBReader.tracker`
        // registry lookup + `tracker.observe` actor work CANNOT run inline
        // — the compiler forces the detached Task (and the synchronous
        // call site at HookRouter's `entityObserver?(...)` would fail to
        // build if the signature turned async). A tight burst of calls
        // must therefore complete promptly; a regression that bridges the
        // actor work back onto this thread (e.g. a semaphore wait on the
        // detached task) would stall the pool and time this out.
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for i in 0..<200 {
                KBObserver.observeHookEvent(
                    toolName: "Edit",
                    toolInput: ["file_path": "/tmp/a-\(i).swift", "prompt": "text mentioning some entities"]
                )
            }
            done.signal()
        }
        #expect(
            done.wait(timeout: .now() + 5) == .success,
            "KBObserver.observeHookEvent blocked — the registry/actor work is running inline instead of in the detached Task"
        )
    }

    // MARK: - 4. trustFlagSink persistence is off the response path (bullet 4)

    @Test("handle() does not block on trustFlagSink persistence — a deliberately slow sink does not stall the response path")
    func trustFlagSinkDoesNotBlockHandle() {
        let mySid = "sid-a1-flagsink-nonblock-\(UUID().uuidString)"
        let original = HookRouter.trustFlagSink
        let sinkEntered = DispatchSemaphore(value: 0)
        let releaseSink = DispatchSemaphore(value: 0)

        // Session-scoped delegation: only OUR flags hit the blocking test
        // sink; every other session (peer suites) passes through to the
        // real production sink untouched. Guard the swap with HookSeamLock
        // per the seam-override discipline.
        HookSeamLock.withLock {
            HookRouter.trustFlagSink = { flag, score in
                if flag.sessionId == mySid {
                    sinkEntered.signal()
                    releaseSink.wait()
                } else {
                    original(flag, score)
                }
            }
        }
        defer {
            // Unblock any parked sink calls, then restore.
            for _ in 0..<16 { releaseSink.signal() }
            HookSeamLock.withLock { HookRouter.trustFlagSink = original }
        }

        // Fire a burst on a UNIQUE sid (fragmentation buffers are keyed by
        // sessionId, so this is isolated) to trigger a toolBurst flag. A
        // length-1 fragment stays under the stitch minimum and there is no
        // paneId, so ONLY toolBurst fires.
        let evt = Self.makeEvent(
            toolName: "Edit",
            toolInput: ["file_path": "/tmp/x.swift", "prompt": "x"],
            eventName: "PreToolUse",
            sessionId: mySid
        )
        // Each handle() must return without waiting on the (blocked) sink.
        for _ in 0..<5 {
            #expect(
                Self.handleReturns(evt, within: 5) == .success,
                "handle() blocked on the deliberately-slow trustFlagSink — the persistence write is still INLINE on the response path"
            )
        }

        // The burst produced a flag → the sink WAS invoked (in a detached
        // Task) and is parked in releaseSink.wait(). Proves the persistence
        // happens, just off the response path.
        #expect(
            sinkEntered.wait(timeout: .now() + 5) == .success,
            "trustFlagSink never fired for the burst — expected a toolBurst flag to be persisted off the response path"
        )
    }

    // MARK: - 5. exactly-once persistence after the async settles (bullet 5)

    @Test("The moved trust-flag write persists each classified flag exactly once, after the async settles")
    func trustFlagPersistedExactlyOnceAfterAsyncSettles() {
        let path = "/tmp/senkani-a1-flagsink-\(UUID().uuidString).sqlite"
        let tempDB = SessionDatabase(path: path)
        defer { TempSessionDatabase.close(tempDB, path: path) }

        let mySid = "sid-a1-flagsink-exactlyonce-\(UUID().uuidString)"
        let original = HookRouter.trustFlagSink
        let lock = NSLock()
        var received: [FragmentationDetector.Flag] = []

        HookSeamLock.withLock {
            HookRouter.trustFlagSink = { flag, score in
                if flag.sessionId == mySid {
                    // Write FIRST (blocking DB queue.sync), then record —
                    // so "row present in DB" implies "append happened",
                    // which makes the DB flush a clean convergence point.
                    _ = tempDB.recordTrustFlag(flag, score: score)
                    lock.lock(); received.append(flag); lock.unlock()
                } else {
                    original(flag, score)
                }
            }
        }
        defer { HookSeamLock.withLock { HookRouter.trustFlagSink = original } }

        let evt = Self.makeEvent(
            toolName: "Edit",
            toolInput: ["file_path": "/tmp/x.swift", "prompt": "x"],
            eventName: "PreToolUse",
            sessionId: mySid
        )
        for _ in 0..<5 { _ = HookRouter.handle(eventJSON: evt) }

        // The flags are produced synchronously inside handle(); only the
        // persistence Task is async. Poll (bounded) until the DB row count
        // converges with the sink-received count — the point at which every
        // detached persistence Task has settled.
        var rows: [TrustFlagRow] = []
        var receivedCount = 0
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            tempDB.flushWrites()
            rows = tempDB.recentTrustFlags(limit: 100)
            lock.lock(); receivedCount = received.count; lock.unlock()
            if receivedCount >= 1 && rows.count == receivedCount { break }
            Thread.sleep(forTimeInterval: 0.05)
        }

        // At least one flag was persisted AFTER the async settled.
        #expect(rows.count >= 1, "no trust-flag row was persisted after the async settled")
        // Exactly-once at the DB layer: the DB got exactly what the sink
        // received — no drops, no duplicate inserts.
        #expect(rows.count == receivedCount, "DB row count \(rows.count) != sink-received count \(receivedCount) — the async move dropped or duplicated a write")
        // Exactly-once at the classification layer: no flag was handed to
        // the sink twice. `FragmentationDetector.Flag` is Equatable but not
        // Hashable, so dedupe with an Equatable containment walk (n ≤ 5).
        lock.lock()
        var uniqueFlags: [FragmentationDetector.Flag] = []
        for f in received where !uniqueFlags.contains(f) { uniqueFlags.append(f) }
        let uniqueCount = uniqueFlags.count
        let total = received.count
        lock.unlock()
        #expect(uniqueCount == total, "a flag was persisted more than once (received \(total), unique \(uniqueCount))")

        // Audit-chain integrity holds across the async-persisted rows.
        let verdict = ChainVerifier.verifyTrustAudits(tempDB)
        if case .brokenAt(let table, let rowid, let expected, let actual) = verdict {
            Issue.record("trust-audit chain broken at \(table):\(rowid) expected=\(expected) actual=\(actual) after async flag persistence")
        }
    }

    // MARK: - 6. deny decision still fires with async persistence (bullet 6)

    @Test("The PreToolUse .blocking deny still fires with the trust-flag persistence moved async — verdict correctness is unchanged")
    func blockingDenyStillFiresWithAsyncPersistence() {
        let mySid = "sid-a1-deny-\(UUID().uuidString)"
        let originalMode = HookRouter.trustModeReader
        let originalOverride = HookRouter.trustOverrideReader
        // Keep the real production sink (persistence async, off-path) so
        // this test exercises the deny decision WITH the async move live.
        HookSeamLock.withLock {
            HookRouter.trustModeReader = { .blocking }
            HookRouter.trustOverrideReader = { _ in false }
        }
        defer {
            HookSeamLock.withLock {
                HookRouter.trustModeReader = originalMode
                HookRouter.trustOverrideReader = originalOverride
            }
        }

        let evt = Self.makeEvent(
            toolName: "Edit",
            toolInput: ["file_path": "/tmp/x.swift", "prompt": "x"],
            eventName: "PreToolUse",
            sessionId: mySid
        )
        // Burst until the toolBurst flag fires; the deny reads the IN-MEMORY
        // `flags` + `trustModeReader()` (NOT the async-persisted row), so it
        // must still deny even though the row write is deferred.
        var sawDeny = false
        for _ in 0..<6 {
            let resp = HookRouter.handle(eventJSON: evt)
            let s = String(data: resp, encoding: .utf8) ?? ""
            if s.contains("trust mode is blocking") {
                sawDeny = true
                #expect(s.contains("\"permissionDecision\":\"deny\""),
                        "trust-mode denial must surface as permissionDecision=deny")
                break
            }
        }
        #expect(sawDeny, ".blocking mode must still surface the deny after the burst threshold — moving the persistence async must not change the deny decision")
    }
}
