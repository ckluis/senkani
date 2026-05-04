import Foundation

/// Versioned, timestamped per-model cost ledger.
///
/// Why this exists: `ModelPricing.swift` holds today's rates as `static
/// let` constants and computes cost at *display time*. That means
/// changing the active model — or, worse, the upstream provider
/// updating their pricing — silently rebases every historical cost
/// number in the database. The ledger fixes this by keeping rates
/// versioned and effective-dated. A trace row written under `version:1`
/// stays priced at v1 rates forever, even after the operator publishes
/// a v2 ledger.
///
/// New rates land by appending an entry with `effective_from` set to
/// the new date and the prior entry's `effective_to` filled in. A row
/// is "active for date X" when `effective_from ≤ X` and (`effective_to`
/// is nil OR `effective_to > X`).
///
/// The ledger is embedded as a Swift literal so it ships in every
/// binary without resource-bundling plumbing. New entries land by
/// editing this file, which forces a code review.
public struct CostLedgerEntry: Codable, Sendable, Equatable {
    public let modelId: String
    public let displayName: String
    public let inputPerMillion: Double
    public let outputPerMillion: Double
    public let cachedInputPerMillion: Double
    public let effectiveFrom: Date
    public let effectiveTo: Date?
    public let version: Int

    public init(
        modelId: String,
        displayName: String,
        inputPerMillion: Double,
        outputPerMillion: Double,
        cachedInputPerMillion: Double,
        effectiveFrom: Date,
        effectiveTo: Date? = nil,
        version: Int
    ) {
        self.modelId = modelId
        self.displayName = displayName
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.version = version
    }
}

public enum CostLedger {

    /// The current ledger version. Bumped when `entries` gains a new row
    /// for an existing `modelId`. Stamped on every new
    /// `agent_trace_event` write so historical rows can be re-priced
    /// against the rates that were live when they ran.
    public static let currentVersion: Int = 1

    /// Live ledger. Add new rates by appending an entry with the new
    /// `effective_from`, and set the prior entry's `effective_to` to
    /// the same date (closed-open intervals — `[from, to)`).
    public static let entries: [CostLedgerEntry] = [
        // Version 1 — snapshot of ModelPricing.swift constants on
        // 2026-05-03. These rates were in production through this date;
        // any future ledger version must add NEW entries rather than
        // mutate these.
        CostLedgerEntry(
            modelId: "claude-opus-4", displayName: "Claude Opus 4",
            inputPerMillion: 15.0, outputPerMillion: 75.0, cachedInputPerMillion: 1.50,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "claude-sonnet-4", displayName: "Claude Sonnet 4",
            inputPerMillion: 3.0, outputPerMillion: 15.0, cachedInputPerMillion: 0.30,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "claude-haiku-3.5", displayName: "Claude Haiku 3.5",
            inputPerMillion: 0.80, outputPerMillion: 4.0, cachedInputPerMillion: 0.08,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "gpt-4o", displayName: "GPT-4o",
            inputPerMillion: 2.50, outputPerMillion: 10.0, cachedInputPerMillion: 1.25,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "gpt-4o-mini", displayName: "GPT-4o Mini",
            inputPerMillion: 0.15, outputPerMillion: 0.60, cachedInputPerMillion: 0.075,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "o3", displayName: "o3",
            inputPerMillion: 2.0, outputPerMillion: 8.0, cachedInputPerMillion: 1.0,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro",
            inputPerMillion: 1.25, outputPerMillion: 10.0, cachedInputPerMillion: 0.3125,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
        CostLedgerEntry(
            modelId: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash",
            inputPerMillion: 0.15, outputPerMillion: 0.60, cachedInputPerMillion: 0.0375,
            effectiveFrom: epoch, effectiveTo: nil, version: 1
        ),
    ]

    /// Look up the entry that was active for `modelId` at `at`. Returns
    /// nil when the model isn't in the ledger or the date falls outside
    /// every recorded interval. `at` defaults to now — most callers want
    /// "what's the current rate?"
    ///
    /// Resolution order: exact match (case-insensitive) wins over
    /// substring match. When multiple entries' `modelId` substrings
    /// appear in the input, the longest match wins — so `"gpt-4o-mini"`
    /// resolves to the `gpt-4o-mini` entry, not the broader `gpt-4o`.
    public static func rate(model modelId: String, at: Date = Date()) -> CostLedgerEntry? {
        let normalized = modelId.lowercased()
        let active = { (entry: CostLedgerEntry) -> Bool in
            let afterStart = entry.effectiveFrom <= at
            let beforeEnd = entry.effectiveTo.map { at < $0 } ?? true
            return afterStart && beforeEnd
        }

        // Exact match first.
        if let exact = entries.first(where: { $0.modelId.lowercased() == normalized && active($0) }) {
            return exact
        }
        // Substring match — pick the longest modelId that appears in the
        // input so more-specific entries (gpt-4o-mini) beat less-specific
        // ones (gpt-4o).
        let substringHits = entries
            .filter { normalized.contains($0.modelId.lowercased()) && active($0) }
            .sorted { $0.modelId.count > $1.modelId.count }
        return substringHits.first
    }

    /// All entries pinned to a specific version. Used by audit surfaces
    /// that want to show "what rates produced this row?"
    public static func entries(forVersion version: Int) -> [CostLedgerEntry] {
        return entries.filter { $0.version == version }
    }

    /// Look up the entry for `modelId` pinned to a specific ledger
    /// `version`. Reprice paths use this to find the rate a historical
    /// row was originally priced under (its stamped
    /// `cost_ledger_version`), independent of which entry is currently
    /// active. Resolution order matches `rate(model:at:)`: exact
    /// case-insensitive match wins, otherwise the longest substring
    /// match.
    public static func rate(model modelId: String, version: Int) -> CostLedgerEntry? {
        let normalized = modelId.lowercased()
        let candidates = entries.filter { $0.version == version }
        if let exact = candidates.first(where: { $0.modelId.lowercased() == normalized }) {
            return exact
        }
        return candidates
            .filter { normalized.contains($0.modelId.lowercased()) }
            .sorted { $0.modelId.count > $1.modelId.count }
            .first
    }

    /// Stable epoch used as the universal `effective_from` for the v1
    /// snapshot. Using `Date(timeIntervalSince1970: 0)` rather than a
    /// specific date means v1 covers "every trace row written before
    /// the first dated entry lands" without gaps.
    private static let epoch = Date(timeIntervalSince1970: 0)
}
