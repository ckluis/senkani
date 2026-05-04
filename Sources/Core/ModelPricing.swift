import Foundation

/// Centralized model pricing for cost estimation.
///
/// Senkani primarily saves **input tokens** — by compressing tool output, fewer
/// tokens are sent to the model. All prices are USD per million tokens.
///
/// `ModelPricing` is now a thin facade over ``CostLedger``: instance fields
/// are populated from the live ledger entry on construction, and lookups
/// (``find(_:)``, ``allModels``) read the ledger so the two never drift.
/// The named static constants (``claudeOpus4`` etc.) remain as
/// convenience handles for back-compat with call sites that reference a
/// specific model by name; their values mirror their ledger entries
/// byte-for-byte (verified by ``ModelPricingLedgerParityTests``).
///
/// To add a new model: append a new entry to ``CostLedger.entries`` —
/// ``allModels`` will surface it automatically.
public struct ModelPricing: Codable, Sendable, Identifiable {
    public var id: String { modelId }
    public let modelId: String
    public let displayName: String
    public let inputPerMillion: Double       // $/M input tokens
    public let outputPerMillion: Double      // $/M output tokens
    public let cachedInputPerMillion: Double // $/M cached input tokens

    public init(modelId: String, displayName: String,
                inputPerMillion: Double, outputPerMillion: Double,
                cachedInputPerMillion: Double) {
        self.modelId = modelId
        self.displayName = displayName
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
    }
}

// MARK: - Known Models

extension ModelPricing {
    // Claude 4 family
    public static let claudeOpus4 = ModelPricing(
        modelId: "claude-opus-4",
        displayName: "Claude Opus 4",
        inputPerMillion: 15.0, outputPerMillion: 75.0, cachedInputPerMillion: 1.50
    )
    public static let claudeSonnet4 = ModelPricing(
        modelId: "claude-sonnet-4",
        displayName: "Claude Sonnet 4",
        inputPerMillion: 3.0, outputPerMillion: 15.0, cachedInputPerMillion: 0.30
    )
    public static let claudeHaiku35 = ModelPricing(
        modelId: "claude-haiku-3.5",
        displayName: "Claude Haiku 3.5",
        inputPerMillion: 0.80, outputPerMillion: 4.0, cachedInputPerMillion: 0.08
    )

    // OpenAI family
    public static let gpt4o = ModelPricing(
        modelId: "gpt-4o",
        displayName: "GPT-4o",
        inputPerMillion: 2.50, outputPerMillion: 10.0, cachedInputPerMillion: 1.25
    )
    public static let gpt4oMini = ModelPricing(
        modelId: "gpt-4o-mini",
        displayName: "GPT-4o Mini",
        inputPerMillion: 0.15, outputPerMillion: 0.60, cachedInputPerMillion: 0.075
    )
    public static let o3 = ModelPricing(
        modelId: "o3",
        displayName: "o3",
        inputPerMillion: 2.0, outputPerMillion: 8.0, cachedInputPerMillion: 1.0
    )

    // Google family
    public static let gemini25Pro = ModelPricing(
        modelId: "gemini-2.5-pro",
        displayName: "Gemini 2.5 Pro",
        inputPerMillion: 1.25, outputPerMillion: 10.0, cachedInputPerMillion: 0.3125
    )
    public static let gemini25Flash = ModelPricing(
        modelId: "gemini-2.5-flash",
        displayName: "Gemini 2.5 Flash",
        inputPerMillion: 0.15, outputPerMillion: 0.60, cachedInputPerMillion: 0.0375
    )

    /// All known model pricings — derived from
    /// ``CostLedger.entries(forVersion:)`` at the live ``CostLedger.currentVersion``.
    /// New models land by appending to ``CostLedger.entries``; this view
    /// surfaces them automatically without duplicating data.
    public static var allModels: [ModelPricing] {
        CostLedger.entries(forVersion: CostLedger.currentVersion).map(ModelPricing.init(ledgerEntry:))
    }

    /// Materialize a `ModelPricing` from a `CostLedgerEntry`.
    public init(ledgerEntry entry: CostLedgerEntry) {
        self.modelId = entry.modelId
        self.displayName = entry.displayName
        self.inputPerMillion = entry.inputPerMillion
        self.outputPerMillion = entry.outputPerMillion
        self.cachedInputPerMillion = entry.cachedInputPerMillion
    }
}

// MARK: - Active Model (user-configurable)

extension ModelPricing {
    /// Key used for UserDefaults persistence.
    private static let activeModelKey = "senkani.activeModelId"

    /// The model used for all cost calculations. Defaults to Claude Sonnet 4.
    /// Persisted to UserDefaults so it survives app restarts.
    public static var active: ModelPricing {
        get {
            if let id = UserDefaults.standard.string(forKey: activeModelKey) {
                return find(id)
            }
            return .claudeSonnet4
        }
        set {
            UserDefaults.standard.set(newValue.modelId, forKey: activeModelKey)
        }
    }

    /// Look up pricing by model ID. Delegates to ``CostLedger.rate(model:at:)``
    /// — the ledger is the single source of truth — and falls back to
    /// `claudeSonnet4` when no entry matches.
    public static func find(_ modelId: String) -> ModelPricing {
        if let entry = CostLedger.rate(model: modelId) {
            return ModelPricing(ledgerEntry: entry)
        }
        return .claudeSonnet4
    }
}

// MARK: - Cost Calculation

extension ModelPricing {
    /// Bytes per token approximation (industry standard for English text).
    public static let bytesPerToken: Double = 4.0

    /// Convert bytes to estimated token count.
    public static func bytesToTokens(_ bytes: Int) -> Int {
        max(0, Int(Double(bytes) / bytesPerToken))
    }

    /// Estimate cost saved from compressed input bytes using the active model.
    /// This is the primary Senkani metric: bytes NOT sent to the model.
    public static func costSaved(bytes: Int) -> Double {
        active.inputCostForBytes(bytes)
    }

    /// Estimate cost saved in cents (for budget system and database).
    public static func costSavedCents(bytes: Int) -> Int {
        Int(costSaved(bytes: bytes) * 100)
    }

    /// Format a dollar amount for display.
    public static func formatCost(_ dollars: Double) -> String {
        if dollars >= 0.01 {
            return String(format: "$%.2f", dollars)
        }
        if dollars > 0 {
            return String(format: "$%.3f", dollars)
        }
        return "$0.00"
    }

    /// Cost of input tokens for a given byte count at this model's rate.
    public func inputCostForBytes(_ bytes: Int) -> Double {
        let tokens = Double(bytes) / Self.bytesPerToken
        return (tokens / 1_000_000) * inputPerMillion
    }

    /// Cost of output tokens for a given byte count at this model's rate.
    public func outputCostForBytes(_ bytes: Int) -> Double {
        let tokens = Double(bytes) / Self.bytesPerToken
        return (tokens / 1_000_000) * outputPerMillion
    }
}
