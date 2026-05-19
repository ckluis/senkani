import Foundation

/// The four-name vocabulary U.2a-1 ships for browser-validation axes.
///
/// `perf` + `completeness` get assertion libraries in U.2a-2.
/// `security` + `design` get assertion libraries in U.2b-axes.
/// The vocabulary lands here in U.2a-1 so downstream rounds only add
/// NEW assertions — the rawValue contract stays stable.
///
/// Stable string values are the schema-level surface. Adding a new
/// axis is a breaking change for any consumer that decodes axis
/// arrays from `validation_results.axes` (TEXT, JSON array).
public enum ValidationAxes: String, Sendable, CaseIterable, Hashable, Codable {
    case perf
    case security
    case design
    case completeness
}
