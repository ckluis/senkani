import Foundation

/// User-facing savings surfaces. Each surface has a default
/// `Confidence` tier per `spec/testing.md` → "Confidence Tiers for
/// Reported Savings". Centralizing the mapping here keeps the
/// discipline rule (an `estimated` number must never be presented as
/// `exact`) checkable from a single source of truth — both the
/// SwiftUI badge sites and the test target read this enum.
public enum SavingsSurface: String, Sendable {
    case fixtureBench
    case liveSessionReplay
    case scenarioSimulator
}

public extension Confidence {
    /// Default tier for the given user-facing surface.
    ///
    /// `liveSessionReplay` is `.estimated` (not `.exact`) because the
    /// cost-saved component depends on a runtime-mutable
    /// `ModelPricing.active`. The token component is exact, but per
    /// `loosened(by:)` the surface-level rollup is `.estimated`.
    /// If a future round wires `cost_ledger_version`-backed display
    /// so live-mode cost is exact-by-row, reconsider promoting back
    /// to `.exact` (see `cost-ledger-single-source` work).
    static func defaultForSurface(_ surface: SavingsSurface) -> Confidence {
        switch surface {
        case .fixtureBench:      return .exact
        case .liveSessionReplay: return .estimated
        case .scenarioSimulator: return .estimated
        }
    }
}
