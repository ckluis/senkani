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
/// already torn down. Pre-audit confirmed only two suites read/write the
/// sink (`LoggerRoutingTests`, `StoreExecTests`), but production
/// `Logger.log` callers fire from arbitrary GCD queues, ruling out a
/// `@TaskLocal` rewrite (GCD closures don't inherit task-locals).
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
