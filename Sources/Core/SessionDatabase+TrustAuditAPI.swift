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

    // MARK: - U.4b-1 promotion + override (Phase U.4b-1)

    /// Persist a `set-mode` flip as a chained `promotion` row. Returns
    /// the new rowid or -1 on failure.
    @discardableResult
    public func recordTrustPromotion(
        from: String,
        to: String,
        fpRateMax: Double?,
        minLabeledSample: Int?,
        observedRate: Double?,
        observedSample: Int,
        promotedBy: String,
        at: Date = Date()
    ) -> Int64 {
        return trustAuditStore.recordPromotion(
            from: from, to: to,
            fpRateMax: fpRateMax, minLabeledSample: minLabeledSample,
            observedRate: observedRate, observedSample: observedSample,
            promotedBy: promotedBy, at: at
        )
    }

    /// Persist a per-call override as a chained `override` row. Returns
    /// the new rowid or -1 on failure.
    @discardableResult
    public func recordTrustOverride(
        callId: String,
        flagId: Int64? = nil,
        operator opAlias: String,
        justification: String? = nil,
        at: Date = Date()
    ) -> Int64 {
        return trustAuditStore.recordOverride(
            callId: callId, flagId: flagId,
            operator: opAlias, justification: justification, at: at
        )
    }

    /// True when an `override` row exists for the given callId.
    /// HookRouter denial path reads this before refusing.
    public func trustOverrideExists(callId: String) -> Bool {
        return trustAuditStore.overrideExists(callId: callId)
    }
}
