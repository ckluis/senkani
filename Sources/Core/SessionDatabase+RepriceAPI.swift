import Foundation

/// Result of repricing a stored `agent_trace_event` row against the
/// current ``CostLedger`` version. The original `costCents` stays
/// authoritative for accounting; `repricedCents` is the projection
/// "what would this have cost under today's rates?" Display surfaces
/// MUST tag the repriced number with `confidence` per the
/// confidence-tier discipline (see `spec/testing.md`).
public struct RepricedTrace: Sendable, Equatable {
    /// Cents as stored on the row (priced under ``originalVersion``).
    public let originalCents: Int
    /// Cents the row would carry under the live
    /// ``CostLedger.currentVersion`` rates. Equal to ``originalCents``
    /// when versions match or when reprice can't be computed.
    public let repricedCents: Int
    /// Ledger version stamped on the row at write time. nil for rows
    /// written before migration v16.
    public let originalVersion: Int?
    /// Live ledger version the reprice scaled to.
    public let currentVersion: Int
    /// Confidence tier for the repriced number. Honors the discipline
    /// in `spec/testing.md`: `exact` when no rebase happened,
    /// `needs_validation` when versions diverged (projection),
    /// `unsupported` when reprice can't be computed.
    public let confidence: ConfidenceTier

    public enum ConfidenceTier: String, Sendable, Equatable, Codable {
        case exact
        case needsValidation = "needs_validation"
        case unsupported
    }

    public init(
        originalCents: Int,
        repricedCents: Int,
        originalVersion: Int?,
        currentVersion: Int,
        confidence: ConfidenceTier
    ) {
        self.originalCents = originalCents
        self.repricedCents = repricedCents
        self.originalVersion = originalVersion
        self.currentVersion = currentVersion
        self.confidence = confidence
    }

    /// `true` when the repriced cents differ from the original — i.e.
    /// the row was written under an older ledger version and the
    /// current ledger has different rates for its model. Display
    /// surfaces use this to decide whether to show the rebased number
    /// at all.
    public var didReprice: Bool { repricedCents != originalCents }
}

extension SessionDatabase {

    /// Reprice a stored canonical trace row against the live ledger
    /// version. Reads the row's ``AgentTraceEvent/costLedgerVersion``,
    /// looks up the rate that produced its ``AgentTraceEvent/costCents``,
    /// and scales by the ratio of the current input rate to the
    /// historical one.
    ///
    /// Per the confidence-tier discipline:
    /// - same version (or row pre-migration-v16) → ``RepricedTrace/ConfidenceTier/exact``
    /// - different version, both rates resolvable → ``RepricedTrace/ConfidenceTier/needsValidation``
    /// - row.model nil OR ledger lookup fails → ``RepricedTrace/ConfidenceTier/unsupported``
    ///
    /// `asOf` defaults to now; pass an explicit date when projecting a
    /// past or future ledger window.
    public func repriceTraceRow(_ row: AgentTraceEvent, asOf: Date = Date()) -> RepricedTrace {
        return Self.repriceTraceRow(row, asOf: asOf)
    }

    /// Reprice a U.1c drill-down row. Drill-down rows carry only the
    /// fields the chart sheet needs; this overload builds a synthetic
    /// `AgentTraceEvent` for the reprice computation so the sheet can
    /// surface a tagged repriced number without re-querying the full
    /// canonical row.
    public func repriceTraceRow(_ row: AgentTraceTierRow, asOf: Date = Date()) -> RepricedTrace {
        return Self.repriceTierRow(row, asOf: asOf)
    }

    public static func repriceTierRow(_ row: AgentTraceTierRow, asOf: Date = Date()) -> RepricedTrace {
        let synthetic = AgentTraceEvent(
            idempotencyKey: row.idempotencyKey,
            pane: row.pane, project: row.project, model: row.model,
            tier: row.tier, ladderPosition: row.ladderPosition,
            feature: row.feature,
            result: row.result,
            startedAt: row.startedAt, completedAt: row.startedAt,
            latencyMs: row.latencyMs,
            tokensIn: row.tokensIn, tokensOut: row.tokensOut,
            costCents: row.costCents,
            costLedgerVersion: row.costLedgerVersion
        )
        return repriceTraceRow(synthetic, asOf: asOf)
    }

    /// Static form of ``repriceTraceRow(_:asOf:)`` — convenient for
    /// tests and call sites that hold a row but no `SessionDatabase`
    /// handle. Reprice is a pure function over (row, ledger, asOf); it
    /// touches no DB state.
    public static func repriceTraceRow(_ row: AgentTraceEvent, asOf: Date = Date()) -> RepricedTrace {
        let currentVersion = CostLedger.currentVersion
        // No version stamped → row pre-dates migration v16. Treat as
        // current; no rebase to do.
        guard let originalVersion = row.costLedgerVersion else {
            return RepricedTrace(
                originalCents: row.costCents,
                repricedCents: row.costCents,
                originalVersion: nil,
                currentVersion: currentVersion,
                confidence: .exact
            )
        }
        // Same version → no rebase.
        if originalVersion == currentVersion {
            return RepricedTrace(
                originalCents: row.costCents,
                repricedCents: row.costCents,
                originalVersion: originalVersion,
                currentVersion: currentVersion,
                confidence: .exact
            )
        }
        // Cross-version reprice requires both rates AND a model id.
        guard let modelId = row.model,
              let originalEntry = CostLedger.rate(model: modelId, version: originalVersion),
              let currentEntry = CostLedger.rate(model: modelId, at: asOf),
              originalEntry.inputPerMillion > 0
        else {
            return RepricedTrace(
                originalCents: row.costCents,
                repricedCents: row.costCents,
                originalVersion: originalVersion,
                currentVersion: currentVersion,
                confidence: .unsupported
            )
        }
        let scale = currentEntry.inputPerMillion / originalEntry.inputPerMillion
        let reprised = Int((Double(row.costCents) * scale).rounded())
        return RepricedTrace(
            originalCents: row.costCents,
            repricedCents: reprised,
            originalVersion: originalVersion,
            currentVersion: currentVersion,
            confidence: reprised == row.costCents ? .exact : .needsValidation
        )
    }
}
