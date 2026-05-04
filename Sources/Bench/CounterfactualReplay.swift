import Core
import Foundation

/// Counterfactual replay (Mode 4 in `spec/testing.md`).
///
/// Replays a recorded session under an alternate optimization policy
/// and reports the delta — tokens, cost, rows affected — without
/// executing any tool calls or writing to the project. Pure function
/// over a list of `AgentTraceEvent` rows plus a `ReplayPreset`.
///
/// V1 ships two presets:
///   - `outline-first-strict`: assume every `read` row that wasn't
///     already an outline would have been served as an outline (~90%
///     output reduction). Estimated, not exact, because the agent's
///     real demand for full content depends on call content the trace
///     doesn't record.
///   - `budget-tight`: walk the rows in chronological order with a
///     stricter session budget cap. Rows past the cumulative cap are
///     marked as "would have been blocked." The cap-walk itself is
///     deterministic (`exact`); whether the agent's work could have
///     been completed before the block is `needs_validation`.
///
/// Never re-executes shell commands. Never writes to the project. Never
/// modifies the live config. Replay rows are derived data — drop them
/// any time and they reproduce.
public enum CounterfactualReplay {

    /// Replay `rows` under `preset` and return the delta report.
    /// `now` is provided for deterministic timestamp testing; defaults
    /// to the wall clock.
    public static func evaluate(
        sessionId: String,
        rows: [AgentTraceEvent],
        preset: ReplayPreset,
        budgetCapCents: Int? = nil,
        now: Date = Date()
    ) -> ReplayReport {
        switch preset {
        case .outlineFirstStrict:
            return outlineFirstStrict(sessionId: sessionId, rows: rows, now: now)
        case .budgetTight:
            return budgetTight(sessionId: sessionId, rows: rows, capCents: budgetCapCents, now: now)
        }
    }

    // MARK: - outline-first-strict

    /// Reduces `tokens_out` by 90% on every full-file `read` row. Re-reads
    /// (`feature == "outline_read"` or `result == "cached"`) are unaffected;
    /// they were already small. Confidence: `estimated` because the
    /// reduction ratio is a population average from the fixture bench,
    /// not a row-by-row measurement.
    private static func outlineFirstStrict(
        sessionId: String,
        rows: [AgentTraceEvent],
        now: Date
    ) -> ReplayReport {
        let baseline = totals(of: rows)
        var counterfactualTokensOut = 0
        var counterfactualCostCents = 0
        var affected = 0
        var notes: [String] = []

        for row in rows {
            let isFullRead = (row.feature == "read" || row.feature == "fetch")
                && row.result != "cached"
                && row.tokensOut > 0
            if isFullRead {
                let reducedOut = Int(Double(row.tokensOut) * 0.10)
                let reducedCost = Int(Double(row.costCents) * 0.10)
                counterfactualTokensOut += reducedOut
                counterfactualCostCents += reducedCost
                affected += 1
            } else {
                counterfactualTokensOut += row.tokensOut
                counterfactualCostCents += row.costCents
            }
        }

        if affected == 0 {
            notes.append("No `read` or `fetch` rows in the trace — preset has no effect.")
        } else {
            notes.append("Reduction ratio (90%) is a fixture-bench average; per-row variance is not modeled.")
        }

        let counterfactual = ReplayTotals(
            totalTokensIn: baseline.totalTokensIn,
            totalTokensOut: counterfactualTokensOut,
            totalCostCents: counterfactualCostCents,
            rowCount: rows.count
        )

        return ReplayReport(
            preset: .outlineFirstStrict,
            sessionId: sessionId,
            evaluatedAt: now,
            baseline: baseline,
            counterfactual: counterfactual,
            affectedRowCount: affected,
            confidence: rows.isEmpty ? .unsupported : .estimated,
            notes: notes
        )
    }

    // MARK: - budget-tight

    /// Walk rows in chronological order, accumulating cost. The first
    /// row whose cumulative cost crosses `capCents` is the cutoff —
    /// everything after is "would have been blocked." Returns
    /// `unsupported` if no cap is supplied.
    private static func budgetTight(
        sessionId: String,
        rows: [AgentTraceEvent],
        capCents: Int?,
        now: Date
    ) -> ReplayReport {
        let baseline = totals(of: rows)

        guard let cap = capCents else {
            return ReplayReport(
                preset: .budgetTight,
                sessionId: sessionId,
                evaluatedAt: now,
                baseline: baseline,
                counterfactual: baseline,
                affectedRowCount: 0,
                confidence: .unsupported,
                notes: ["Pass --budget-cents to evaluate budget-tight."]
            )
        }

        var cumulative = 0
        var blockedAt: Int? = nil
        for (idx, row) in rows.enumerated() {
            cumulative += row.costCents
            if cumulative > cap {
                blockedAt = idx
                break
            }
        }

        let preserved = blockedAt.map { Array(rows.prefix($0)) } ?? rows
        let blocked = blockedAt.map { rows.count - $0 } ?? 0
        let counterfactual = totals(of: preserved)

        var notes: [String] = []
        if let cutoff = blockedAt {
            notes.append("Cap of \(cap)¢ hit at row \(cutoff + 1) (cumulative \(cumulative)¢). \(blocked) rows would have been blocked.")
        } else {
            notes.append("Total cost (\(cumulative)¢) stayed under cap (\(cap)¢) — no rows would have been blocked.")
        }
        notes.append("Cap-walk is deterministic; whether the agent's work would have completed before the block is `needs_validation`.")

        return ReplayReport(
            preset: .budgetTight,
            sessionId: sessionId,
            evaluatedAt: now,
            baseline: baseline,
            counterfactual: ReplayTotals(
                totalTokensIn: counterfactual.totalTokensIn,
                totalTokensOut: counterfactual.totalTokensOut,
                totalCostCents: counterfactual.totalCostCents,
                rowCount: counterfactual.rowCount
            ),
            affectedRowCount: blocked,
            // Cap-walk is exact; effect on outcome needs validation.
            confidence: blockedAt == nil ? .exact : .needsValidation,
            notes: notes
        )
    }

    // MARK: - Helpers

    private static func totals(of rows: [AgentTraceEvent]) -> ReplayTotals {
        var tIn = 0, tOut = 0, cents = 0
        for row in rows {
            tIn += row.tokensIn
            tOut += row.tokensOut
            cents += row.costCents
        }
        return ReplayTotals(totalTokensIn: tIn, totalTokensOut: tOut, totalCostCents: cents, rowCount: rows.count)
    }
}

/// Replay preset registry. Keep the rawValue in sync with CLI flags —
/// `--policy outline-first-strict` parses through the rawValue.
public enum ReplayPreset: String, Codable, CaseIterable, Sendable {
    case outlineFirstStrict = "outline-first-strict"
    case budgetTight = "budget-tight"
}

/// One side of a replay (baseline = what actually ran;
/// counterfactual = what the alternate policy projects).
public struct ReplayTotals: Codable, Sendable, Equatable {
    public let totalTokensIn: Int
    public let totalTokensOut: Int
    public let totalCostCents: Int
    public let rowCount: Int

    public init(totalTokensIn: Int, totalTokensOut: Int, totalCostCents: Int, rowCount: Int) {
        self.totalTokensIn = totalTokensIn
        self.totalTokensOut = totalTokensOut
        self.totalCostCents = totalCostCents
        self.rowCount = rowCount
    }

    public var totalTokens: Int { totalTokensIn + totalTokensOut }
}

/// Full replay report. Stable JSON envelope — schema-versioned by
/// the file the report came from (this struct's evolution should be
/// additive only). Confidence tier follows the discipline in
/// `spec/testing.md` → "Confidence Tiers for Reported Savings".
public struct ReplayReport: Codable, Sendable, Equatable {
    public let preset: ReplayPreset
    public let sessionId: String
    public let evaluatedAt: Date
    public let baseline: ReplayTotals
    public let counterfactual: ReplayTotals
    public let affectedRowCount: Int
    public let confidence: Confidence
    public let notes: [String]

    public init(
        preset: ReplayPreset,
        sessionId: String,
        evaluatedAt: Date,
        baseline: ReplayTotals,
        counterfactual: ReplayTotals,
        affectedRowCount: Int,
        confidence: Confidence,
        notes: [String]
    ) {
        self.preset = preset
        self.sessionId = sessionId
        self.evaluatedAt = evaluatedAt
        self.baseline = baseline
        self.counterfactual = counterfactual
        self.affectedRowCount = affectedRowCount
        self.confidence = confidence
        self.notes = notes
    }

    public var savedTokens: Int { baseline.totalTokens - counterfactual.totalTokens }
    public var savedCostCents: Int { baseline.totalCostCents - counterfactual.totalCostCents }

    public var savedTokensPercent: Double {
        guard baseline.totalTokens > 0 else { return 0 }
        return Double(savedTokens) / Double(baseline.totalTokens) * 100
    }
}
