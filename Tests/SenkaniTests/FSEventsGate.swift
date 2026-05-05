import Foundation
@_spi(Experimental) import Testing

/// Process-wide serial gate for any test suite that exercises the
/// `FSEventStream` API via `Indexer.FileWatcher` or the
/// `Core.KnowledgeFileLayer` `startWatching` path.
///
/// `.serialized` on a `@Suite` serializes tests *within* that suite
/// only; the four FileWatcher suites (Basic Operation, Filtering,
/// Debouncing, Lifetime Safety) plus `KnowledgeFileLayer — Lifetime
/// Safety` running in parallel under the default Swift Testing runner
/// saturate per-process FSEvents kernel resources. Both Lifetime Safety
/// suites churn 200 watchers per test (the FileWatcher one on
/// `/tmp/senkani-fw-nonexistent-...` paths, the KnowledgeFileLayer one
/// on real `/tmp/senkani-kbfl-...` knowledge dirs); concurrent peer
/// suites then see `FSEventStreamStart failed for
/// /private/var/folders/...` and callbacks that never arrive within
/// the 2 s wait window. Filter-only `swift test --filter "FileWatcher"`
/// runs all 12 tests green in ~0.6 s — the contention is purely
/// full-suite cross-process pressure (see
/// `filewatcher-fsevents-flake-under-parallel-runner-2026-05-04`).
///
/// Same shape as `URLProtocolGateTrait` (see `MockURLProtocolGate.swift`)
/// and `LoggerSinkGateTrait` (see `LoggerSinkGate.swift`) — a
/// continuation-queued async semaphore that ensures the body runs
/// outside the actor and the next `wait()` only succeeds after `signal()`
/// fires. `isRecursive == false` so the trait fires once per suite, not
/// per child test; within-suite ordering is left to the `.serialized`
/// trait already applied alongside it.
///
/// Migration note: `CustomExecutionTrait` is `@_spi(Experimental)` on
/// swift-testing 0.99.0; Swift Testing 6.0+ renames this to `TestScoping`
/// with a `provideScope` method. Update this file together with
/// `MockURLProtocolGate.swift` and `LoggerSinkGate.swift` when the
/// package pin moves.

private actor FSEventsGateSemaphore {
    static let shared = FSEventsGateSemaphore()

    private var available = 1
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }

    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            return
        }
        available += 1
    }
}

struct FSEventsGateTrait: SuiteTrait, TestTrait, CustomExecutionTrait {
    var isRecursive: Bool { false }

    /// Post-suite settle delay. Lifetime-Safety suites intentionally
    /// leak FSEventStream registrations (see the `Implicit ... teardown
    /// survives churn` tests) — even with the iteration count lowered
    /// to 20, the kernel needs a beat to free per-process FSEvents
    /// slots before the next gated suite's `FSEventStreamStart` calls
    /// can succeed. 500 ms is generous; total cost across the five
    /// gated suites is ~2.5 s per full test run.
    static let postSuiteSettle: Duration = .milliseconds(500)

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        await FSEventsGateSemaphore.shared.wait()
        do {
            try await function()
        } catch {
            try? await Task.sleep(for: Self.postSuiteSettle)
            await FSEventsGateSemaphore.shared.signal()
            throw error
        }
        try? await Task.sleep(for: Self.postSuiteSettle)
        await FSEventsGateSemaphore.shared.signal()
    }
}

extension Trait where Self == FSEventsGateTrait {
    /// Serializes execution across every suite carrying this trait,
    /// gating on a process-wide async semaphore. Use on every suite
    /// that constructs an `Indexer.FileWatcher` (or otherwise registers
    /// an `FSEventStream`) so per-process FSEvents kernel resources
    /// aren't exhausted by parallel peer-suite churn.
    static var fsEventsGate: Self { FSEventsGateTrait() }
}
