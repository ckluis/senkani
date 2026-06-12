import Foundation
@_spi(Experimental) import Testing

/// Process-wide serial gate for any test suite that mutates the
/// `NotificationDelivery` process-global router holder (`install(_:)` /
/// `resetForTesting()` / `deliver(_:)` against the installed global).
///
/// `.serialized` on a `@Suite` serializes tests *within* that suite
/// only; Swift Testing still parallelizes ACROSS suites, so a
/// `resetForTesting()` or `install(_:)` in one suite can land inside
/// another suite's install → deliver → assert window (e.g.
/// `ScheduleEndNotifierPrimitiveTests` resetting the holder while
/// `NotificationDeliveryTests` expects its spy router to receive a
/// delivery). Every suite passes in isolation; only the combined
/// parallel run flakes — a textbook shared-mutable-static race.
/// Reproduced once under `--filter` co-scheduling during the t6
/// matrix-UI round (2026-06-11, commit 651ba65).
///
/// This trait wraps the entire suite execution in a continuation-queued
/// async semaphore so suites carrying it run one at a time across the
/// whole process — even when their bodies suspend on `await`. The trait
/// has `isRecursive == false` so it fires once per suite (not per child
/// test); within-suite ordering is left to the `.serialized` trait
/// applied alongside it.
///
/// Mirror of `BrowserValidationGateReaderGateTrait`
/// (BrowserValidationGateReaderGate.swift), `URLProtocolGateTrait`
/// (MockURLProtocolGate.swift), and `LoggerSinkGateTrait`
/// (LoggerSinkGate.swift) — same `CustomExecutionTrait` idiom. Filed
/// under `test-flake-notificationdelivery-cross-suite-global-race-2026-06-11`.
///
/// NOT needed on `NotificationsMatrixSettingsTests`: its live-reload
/// suite deliberately exercises the reloaded router VALUE (a local
/// `NotificationRouter`), never the global holder, and its other suites
/// are pure value/source-text checks.
///
/// Migration note: this uses `CustomExecutionTrait`, which is
/// `@_spi(Experimental)` on swift-testing 0.99.0. Swift Testing 6.0+
/// renames this to `TestScoping` with a `provideScope` method. When the
/// package pin moves past 6.0, replace the conformance below (track the
/// other gate traits in lockstep).

private actor NotificationDeliverySemaphore {
    static let shared = NotificationDeliverySemaphore()

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

struct NotificationDeliveryGateTrait: SuiteTrait, TestTrait, CustomExecutionTrait {
    var isRecursive: Bool { false }

    @Sendable func execute(
        _ function: @escaping @Sendable () async throws -> Void,
        for test: Test,
        testCase: Test.Case?
    ) async throws {
        await NotificationDeliverySemaphore.shared.wait()
        do {
            try await function()
        } catch {
            await NotificationDeliverySemaphore.shared.signal()
            throw error
        }
        await NotificationDeliverySemaphore.shared.signal()
    }
}

extension Trait where Self == NotificationDeliveryGateTrait {
    /// Serializes execution across every suite carrying this trait,
    /// gating on a process-wide async semaphore. Use on every suite that
    /// installs into or resets the `NotificationDelivery` process-global.
    static var notificationDeliveryGate: Self { NotificationDeliveryGateTrait() }
}
