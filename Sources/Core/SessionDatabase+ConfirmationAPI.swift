import Foundation

/// Public API for the T.6a confirmation log. Forwards to the store;
/// kept as an extension to match the per-feature `+API.swift`
/// convention used elsewhere on `SessionDatabase`.
extension SessionDatabase {

    /// Insert one confirmation row. Returns the new rowid, or -1 on
    /// failure. Synchronous — the gate calls this inline before the
    /// caller proceeds.
    @discardableResult
    public func recordConfirmation(_ row: ConfirmationRow) -> Int64 {
        return confirmationStore.record(row)
    }

    /// Total confirmation count. For tests + diagnostics.
    public func confirmationCount() -> Int {
        return confirmationStore.count()
    }

    /// Recent confirmation rows, newest first.
    public func recentConfirmations(limit: Int = 50) -> [ConfirmationRow] {
        return confirmationStore.recent(limit: limit)
    }
}
