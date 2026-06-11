import Foundation

/// U.4b-2a — headless service layer behind the U.4b-2 GUI surfaces
/// (TrustFlagsView mode-toggle pill + per-flag Override button).
///
/// U.4b-1 distributed the mode-flip flow inside `Trust.SetMode.run()`
/// (Sources/CLI/TrustCommand.swift): load settings → query 30-day
/// stats → compute observed rate → `PromotionGate.evaluate` → record
/// chain row → save settings. A GUI calling `TrustSettingsStore.save`
/// directly would bypass the gate and break Schneier's checkable-
/// invariant guarantee (U.4b-2 abort note, 2026-05-20). This service
/// packages that flow as a pure headless seam over an injected
/// `database:` so every surface — SwiftUI pill, Override sheet, or
/// future automation — routes through the same gate logic.
///
/// No GUI dependency; unit-testable via `SessionDatabase(path:)` +
/// a temp `settingsPath`.
public struct TrustGateService: Sendable {
    private let database: SessionDatabase
    private let settingsPath: String

    /// - Parameters:
    ///   - database: Audit-row sink + 30-day stats source. Tests pass
    ///     `SessionDatabase(path:)`; production passes `.shared`.
    ///   - settingsPath: `trust.json` location. Defaults to the
    ///     canonical `~/.senkani/trust.json` (honors `SENKANI_HOME`).
    public init(database: SessionDatabase, settingsPath: String = TrustSettingsPath.canonical()) {
        self.database = database
        self.settingsPath = settingsPath
    }

    // MARK: - Mode flip

    /// Outcome of a `flip(to:by:)` request.
    public enum FlipResult: Sendable, Equatable {
        /// Mode changed. The chained `promotion` row was written
        /// (rowid carried for GUI display) and settings persisted.
        /// `observedRate`/`observedSample` are the gate witnesses for
        /// promotions; nil/0 on the always-allowed demotion path.
        case flipped(from: TrustMode, to: TrustMode, rowid: Int64, observedRate: Double?, observedSample: Int)
        /// Target equals the current mode — idempotent no-op. No row
        /// written, settings untouched.
        case noop(mode: TrustMode)
        /// `PromotionGate` rejected the `.softFlag → .blocking`
        /// request. Reason is the structured string the GUI toggle
        /// displays inline (Norman verdict). No row, no settings write.
        case rejected(reason: String)
        /// The chained audit row failed to write. The flip does NOT
        /// persist — the chain row is the audit witness, so a mode
        /// change without one would be an unwitnessed flip.
        case failed
    }

    /// Current persisted mode. Missing `trust.json` → `.softFlag`
    /// (fresh-install posture). Throws on corrupt JSON — never
    /// silently overrides operator-set values.
    public func currentMode() throws -> TrustMode {
        return try TrustSettingsStore.load(path: settingsPath).mode
    }

    /// Flip the trust mode. Promotion (`.softFlag → .blocking`) runs
    /// the `PromotionGate` against the injected database's 30-day
    /// labeled-sample window; demotion (`.blocking → .softFlag`) is
    /// always allowed. Both record one chained `promotion` row via the
    /// U.4b-1 sink before persisting settings. Flipping to the current
    /// mode is an idempotent no-op (no row, no write).
    @discardableResult
    public func flip(to target: TrustMode, by operatorAlias: String, now: Date = Date()) throws -> FlipResult {
        var settings = try TrustSettingsStore.load(path: settingsPath)
        let from = settings.mode
        guard target != from else { return .noop(mode: from) }

        if target == .blocking {
            let stats = database.trustFlagStatsLast30Days(now: now)
            let observedRate = PromotionGate.observedRate(fp: stats.confirmedFP, tp: stats.confirmedTP)
            let observedSample = stats.confirmedFP + stats.confirmedTP
            let decision = PromotionGate.evaluate(
                fpRateMax: settings.fpRateMax,
                minLabeledSample: settings.minLabeledSample,
                observedRate: observedRate,
                observedSample: observedSample
            )
            switch decision {
            case .accept:
                let rowid = database.recordTrustPromotion(
                    from: from.rawValue, to: target.rawValue,
                    fpRateMax: settings.fpRateMax,
                    minLabeledSample: settings.minLabeledSample,
                    observedRate: observedRate,
                    observedSample: observedSample,
                    promotedBy: operatorAlias,
                    at: now
                )
                guard rowid > 0 else { return .failed }
                settings.mode = target
                try TrustSettingsStore.save(settings, path: settingsPath)
                return .flipped(from: from, to: target, rowid: rowid, observedRate: observedRate, observedSample: observedSample)
            case .reject(let reason):
                return .rejected(reason: reason)
            }
        }

        // Demotion path: always allowed; still records the witness row.
        let rowid = database.recordTrustPromotion(
            from: from.rawValue, to: target.rawValue,
            fpRateMax: nil, minLabeledSample: nil,
            observedRate: nil, observedSample: 0,
            promotedBy: operatorAlias,
            at: now
        )
        guard rowid > 0 else { return .failed }
        settings.mode = target
        try TrustSettingsStore.save(settings, path: settingsPath)
        return .flipped(from: from, to: target, rowid: rowid, observedRate: nil, observedSample: 0)
    }

    // MARK: - Per-call override

    /// Outcome of a `recordOverride(callId:...)` request.
    public enum OverrideResult: Sendable, Equatable {
        /// Chained `override` row written; rowid carried for display.
        case recorded(rowid: Int64)
        /// An override row already covers this callId — idempotent
        /// skip, no duplicate row (the HookRouter allowlist is
        /// per-callId; a second row would be audit noise).
        case alreadyRecorded
        /// The chained audit row failed to write.
        case failed
    }

    /// Re-allow a single denied call by id. Writes one chained
    /// `override` row via the U.4b-1 sink. Idempotent — a callId that
    /// already has an override row returns `.alreadyRecorded` without
    /// writing a duplicate.
    @discardableResult
    public func recordOverride(
        callId: String,
        flagId: Int64? = nil,
        by operatorAlias: String,
        justification: String? = nil,
        at: Date = Date()
    ) -> OverrideResult {
        if database.trustOverrideExists(callId: callId) {
            return .alreadyRecorded
        }
        let rowid = database.recordTrustOverride(
            callId: callId, flagId: flagId,
            operator: operatorAlias, justification: justification, at: at
        )
        guard rowid > 0 else { return .failed }
        return .recorded(rowid: rowid)
    }
}
