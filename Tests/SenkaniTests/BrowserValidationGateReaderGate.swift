import Foundation
@_spi(Experimental) import Testing

/// Process-wide serial gate for any test suite that mutates
/// `HookRouter.browserValidationGateReader` — the `nonisolated(unsafe)`
/// static closure the PreToolUse browser-validation hard-block reads.
///
/// `.serialized` on a `@Suite` serializes tests *within* that suite
/// only; two suites that each swap the static gate reader (save →
/// install canned closure → `HookRouter.handle(...)` → restore via
/// `defer`) still race when run in parallel. The losing test reads the
/// sibling suite's canned row (e.g. `BrowserPaneRunnerParityTests`'
/// `validation_results#102` bleeding into `BrowserValidateDispatchTests`'
/// assertion that expects `#42`). Both suites pass in isolation; only the
/// combined parallel run fails — a textbook shared-mutable-static race.
///
/// This trait wraps the entire suite execution in a continuation-queued
/// async semaphore so suites carrying it run one at a time across the
/// whole process — even when their bodies suspend on `await`. The trait
/// has `isRecursive == false` so it fires once per suite (not per child
/// test); within-suite ordering is left to the `.serialized` trait
/// applied alongside it.
///
/// Mirror of `URLProtocolGateTrait` (MockURLProtocolGate.swift) and
/// `LoggerSinkGateTrait` (LoggerSinkGate.swift) — same `CustomExecutionTrait`
/// idiom. Filed-and-fixed under
/// `phase-u2b-2-dispatch-pane-mcp-cli-parity` (the discovered baseline
/// flake on `HookRouter.browserValidationGateReader`).
///
/// Migration note: this uses `CustomExecutionTrait`, which is
/// `@_spi(Experimental)` on swift-testing 0.99.0. Swift Testing 6.0+
/// renames this to `TestScoping` with a `provideScope` method. When the
/// package pin moves past 6.0, replace the conformance below (track the
/// other two gate traits in lockstep).

private actor BrowserValidationGateReaderSemaphore {
    static let shared = BrowserValidationGateReaderSemaphore()

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

struct BrowserValidationGateReaderGateTrait: SuiteTrait, TestTrait, CustomExecutionTrait {
    var isRecursive: Bool { false }

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        await BrowserValidationGateReaderSemaphore.shared.wait()
        do {
            try await function()
        } catch {
            await BrowserValidationGateReaderSemaphore.shared.signal()
            throw error
        }
        await BrowserValidationGateReaderSemaphore.shared.signal()
    }
}

extension Trait where Self == BrowserValidationGateReaderGateTrait {
    /// Serializes execution across every suite carrying this trait,
    /// gating on a process-wide async semaphore. Use on every suite that
    /// reads or writes `HookRouter.browserValidationGateReader`.
    static var browserValidationGateReaderGate: Self { BrowserValidationGateReaderGateTrait() }
}
