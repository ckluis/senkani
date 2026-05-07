import Foundation

/// Process-wide recursive lock guarding the static seams that
/// `HookRouter.handle()` reads (`ConfirmationGate.resolver`,
/// `HookRouter.annotationFeed`, `HookRouter.packPolicyRegistry`,
/// `HookRouter.trustFlagSink`, `HookRouter.credentialVaultLookup`,
/// `HookRouter.credentialGatewayRecorder`,
/// `HookRouter.credentialGatewayCatalog`,
/// `HookRouter.validationDatabase`, `HookRouter.entityObserver`,
/// `ConfirmationGate.catalog`, `ConfirmationGate.database`).
///
/// Why: tests swap these statics inside `defer`-restore blocks. Under
/// Swift Testing's default-parallel runner, `.serialized` on individual
/// `@Suite`s only orders tests within that suite — sibling suites still
/// run concurrently. A cross-suite race surfaces when one suite holds a
/// non-default resolver while a peer suite reads it through
/// `HookRouter.handle()`. `tools/test-safe.sh` masks this via
/// `SWT_NO_PARALLEL=1`, but raw `swift test --filter` reproduces it
/// reliably.
///
/// Discipline: every test that overrides one of the seams above wraps
/// the override site in `HookSeamLock.withLock { … }`. `HookRouter.handle`
/// reacquires the same lock at entry; `NSRecursiveLock` lets the writer
/// test's body call `HookRouter.handle` without self-deadlocking.
///
/// Production cost: one uncontended `NSRecursiveLock.lock()/unlock()`
/// per `HookRouter.handle` call. Sub-microsecond on macOS — well below
/// the 5 ms hook performance budget.
public enum HookSeamLock {
    nonisolated(unsafe) public static let shared = NSRecursiveLock()

    /// Acquire the seam lock for the duration of `body`, then release.
    /// Tests wrap their seam-override-and-defer block in this helper to
    /// guarantee the override is invisible to peer suites running in
    /// parallel.
    @discardableResult
    public static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        shared.lock()
        defer { shared.unlock() }
        return try body()
    }
}
