import Foundation

extension SessionDatabase {

    /// Persist a fragmentation flag plus its current trust score.
    /// Returns the flag's rowid — the operator labels it later via
    /// `recordTrustLabel(flagId:...)`. Returns -1 on failure.
    @discardableResult
    public func recordTrustFlag(
        _ flag: FragmentationDetector.Flag,
        score: Int
    ) -> Int64 {
        return trustAuditStore.recordFlag(flag, score: score)
    }

    /// Persist an operator FP/TP label for an earlier flag rowid.
    @discardableResult
    public func recordTrustLabel(
        flagId: Int64,
        label: TrustLabel,
        labeledBy: String,
        at: Date = Date()
    ) -> Int64 {
        return trustAuditStore.recordLabel(
            flagId: flagId,
            label: label,
            labeledBy: labeledBy,
            at: at
        )
    }

    /// Recent flags, newest first.
    public func recentTrustFlags(limit: Int = 100, since: Date? = nil) -> [TrustFlagRow] {
        return trustAuditStore.recentFlags(limit: limit, since: since)
    }

    /// Latest label per flag (full history sorted newest first).
    public func trustLabelsForFlag(_ flagId: Int64) -> [TrustLabelRow] {
        return trustAuditStore.labelsForFlag(flagId)
    }

    /// Aggregate stats since `since`. `senkani doctor` reads the 30-
    /// day window.
    public func trustFlagStats(since: Date) -> TrustFlagStats {
        return trustAuditStore.stats(since: since)
    }

    /// 30-day window — convenience for `senkani doctor`.
    public func trustFlagStatsLast30Days(now: Date = Date()) -> TrustFlagStats {
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        return trustAuditStore.stats(since: cutoff)
    }
}
