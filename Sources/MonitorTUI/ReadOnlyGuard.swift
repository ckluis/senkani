import Foundation
import Core

/// Belt-and-suspenders runtime guard for `senkani monitor --tui`.
///
/// V.15a-1's compile-time discipline (MonitorTUI sources never
/// reference `SessionDatabase` write methods directly) is the primary
/// read-only contract. This guard adds runtime defense-in-depth:
///
///   1. The guard's public surface declares ONLY the three
///      `MonitorReadOnlyAPI` read methods. A leaky stub that adds a
///      forbidden write method via extension is unreachable through
///      the guard's surface — the runner only holds the guard, never
///      the underlying API value.
///   2. The guard owns a violation ledger. When the runner spots a
///      defensive concern (an unexpected throw, an out-of-band
///      mutation attempt observed through some other side channel),
///      it can call `recordViolation(_:)`. The `shouldAbortKeystrokeLoop`
///      computed property tells the runner to stop processing input
///      until the operator quits.
///
/// Per Schneier P0 framing: the guard does NOT attempt to fully
/// sandbox an arbitrary `MonitorReadOnlyAPI`-shaped object — that
/// would require capability-based isolation Swift's type system
/// doesn't enforce. It DOES make accidental write-method leaks
/// impossible through the runner's call graph.
public final class TUIReadOnlyGuard: @unchecked Sendable {
    private let api: MonitorReadOnlyAPI
    private let lock = NSLock()
    private var _violations: [String] = []

    public init(api: MonitorReadOnlyAPI) {
        self.api = api
    }

    // MARK: - Read-only passthrough (the entire allowed surface)

    public func snapshot() throws -> PaneRefreshCoordinator.Snapshot {
        return try api.fetchPaneSnapshot()
    }

    public func featureSavings() throws -> [SessionDatabase.FeatureSavings] {
        return try api.fetchFeatureSavings()
    }

    public func projectRows() throws -> [MonitorProjectRow] {
        return try api.fetchProjectRows()
    }

    // MARK: - Violation ledger

    public func recordViolation(_ methodName: String) {
        lock.lock(); defer { lock.unlock() }
        _violations.append(methodName)
    }

    /// Clear the violation ledger so `shouldAbortKeystrokeLoop` returns
    /// to `false`. The operator dismisses the rendered diagnostic and the
    /// loop resumes — that abort → recovery EDGE is what the runner's
    /// `paint()` watches via `sawGuardAbort && !aborted` to force a FULL
    /// repaint (one of the four operator-locked full-repaint triggers).
    ///
    /// Production currently has no UI affordance to dismiss the abort, so
    /// this is exercised primarily by the recovery test; keeping it on the
    /// guard (rather than poking private state from the test) makes the
    /// recovery path a first-class, documented capability instead of a
    /// dead branch.
    public func clearViolations() {
        lock.lock(); defer { lock.unlock() }
        _violations.removeAll()
    }

    public var violations: [String] {
        lock.lock(); defer { lock.unlock() }
        return _violations
    }

    public var shouldAbortKeystrokeLoop: Bool {
        lock.lock(); defer { lock.unlock() }
        return !_violations.isEmpty
    }

    /// Operator-facing diagnostic string (rendered in the footer
    /// when `shouldAbortKeystrokeLoop` is true).
    public var diagnostic: String {
        let names = violations.joined(separator: ", ")
        return "TUIReadOnlyGuard aborted: write-method violation(s) detected: \(names)"
    }
}
