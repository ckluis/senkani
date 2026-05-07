import Foundation
@_spi(Experimental) import Testing

/// Process-wide serial gate for any test suite that installs a sink via
/// `Logger._setTestSink`.
///
/// `Logger._testSink` is a process-global `nonisolated(unsafe) static
/// var` — when two sink-using suites run in parallel under the default
/// Swift Testing runner, one suite's `Logger._setTestSink(nil)` between
/// another's install + observation drops the sibling's events on the
/// floor. The path-filter the LoggerRouting tests apply to `sink.events`
/// only helps for events whose payload includes the test's own path; it
/// can't recover events that never reached the sink because it was
/// already torn down. Three suites read/write the sink today
/// (`LoggerRoutingTests`, `StoreExecTests`, `AgentTraceEventStoreUnknownVocabTests`);
/// production `Logger.log` callers fire from arbitrary GCD queues, ruling
/// out a `@TaskLocal` rewrite (GCD closures don't inherit task-locals).
///
/// **Contract limitation (parent_finding 2026-05-06,
/// `storeexec-niltest-loggersink-leak-from-peer-suite-migration`):** the
/// gate serializes sink-using suites against EACH OTHER. It does NOT
/// block production `Logger.log` emissions from peer suites running in
/// parallel — those land in whichever sink is currently installed,
/// regardless of the calling suite's traits. A peer
/// `SessionDatabase.init` running concurrently can drop
/// `schema.migration.applied` (or any other production event) into a
/// sink-using suite's bag mid-test. Tests that assert sink contents
/// MUST filter `sink.events` by event-name vocabulary (the StoreExec
/// `db.<scope>.sql_error` family) or by a unique field value (the
/// `pathField(...)` filter LoggerRoutingTests uses) — never raw
/// `sink.events.isEmpty`. The three rejected isolation strategies
/// (test-side correlation-id plumbing, `@TaskLocal` rewrite, process-
/// wide write-lock during gated suites) all touch production for a
/// test-only concern; filtering matches the convention the other
/// sibling sites already use.
///
/// Same shape as `URLProtocolGateTrait` (see `MockURLProtocolGate.swift`)
/// — a continuation-queued async semaphore that ensures the body runs
/// outside the actor and the next `wait()` only succeeds after `signal()`
/// fires. `isRecursive == false` so the trait fires once per suite, not
/// per child test; within-suite ordering is left to the `.serialized`
/// trait already applied alongside it.
///
/// Migration note: `CustomExecutionTrait` is `@_spi(Experimental)` on
/// swift-testing 0.99.0; Swift Testing 6.0+ renames this to `TestScoping`
/// with a `provideScope` method. Update both this file and
/// `MockURLProtocolGate.swift` together when the package pin moves.

private actor LoggerSinkGateSemaphore {
    static let shared = LoggerSinkGateSemaphore()

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

struct LoggerSinkGateTrait: SuiteTrait, TestTrait, CustomExecutionTrait {
    var isRecursive: Bool { false }

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        await LoggerSinkGateSemaphore.shared.wait()
        do {
            try await function()
        } catch {
            await LoggerSinkGateSemaphore.shared.signal()
            throw error
        }
        await LoggerSinkGateSemaphore.shared.signal()
    }
}

extension Trait where Self == LoggerSinkGateTrait {
    /// Serializes execution across every suite carrying this trait,
    /// gating on a process-wide async semaphore. Use on every suite
    /// that calls `Logger._setTestSink`.
    static var loggerSinkGate: Self { LoggerSinkGateTrait() }
}
