import Foundation
@_spi(Experimental) import Testing

/// Process-wide serial gate for any test suite that touches
/// MockURLProtocol's process-global stub registry.
///
/// `.serialized` on a `@Suite` serializes tests *within* that suite
/// only; two URLProtocol-using suites running in parallel still race
/// on `MockURLProtocol.stubs` (one suite's `reset()` between another's
/// `register()` and `fetch()` wipes the sibling's stubs — see
/// `swift-testing-parallel-runner-env-var-isolation` backlog item).
///
/// This trait wraps the entire suite execution in a continuation-
/// queued async semaphore so suites carrying the trait run one at a
/// time across the whole process — even when their bodies suspend on
/// `await`. The trait has `isRecursive == false` so it fires once per
/// suite (not per child test) — within-suite serialization is left to
/// the `.serialized` trait already applied alongside it.
///
/// Migration note: this uses `CustomExecutionTrait`, which is
/// `@_spi(Experimental)` on swift-testing 0.99.0. Swift Testing 6.0+
/// renames this to `TestScoping` with a `provideScope` method. When
/// the package pin moves past 6.0, replace the conformance below.

private actor URLProtocolGateSemaphore {
    static let shared = URLProtocolGateSemaphore()

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
            // permit transfers directly to the resumed waiter; do not
            // increment `available`.
            return
        }
        available += 1
    }
}

struct URLProtocolGateTrait: SuiteTrait, TestTrait, CustomExecutionTrait {
    var isRecursive: Bool { false }

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        await URLProtocolGateSemaphore.shared.wait()
        do {
            try await function()
        } catch {
            await URLProtocolGateSemaphore.shared.signal()
            throw error
        }
        await URLProtocolGateSemaphore.shared.signal()
    }
}

extension Trait where Self == URLProtocolGateTrait {
    /// Serializes execution across every suite carrying this trait,
    /// gating on a process-wide async semaphore. Use on every suite
    /// that reads or writes `MockURLProtocol.stubs`.
    static var urlProtocolGate: Self { URLProtocolGateTrait() }
}
