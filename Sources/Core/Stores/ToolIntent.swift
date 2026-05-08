import Foundation

/// Typed vocabulary for `AgentTraceEvent.feature` — the tool intent that
/// produced a canonical trace row. Replaces a primitive `String?` so that
/// typos at write sites (`"Read"` instead of `"read"`,
/// `"file_read"` instead of `"read"`) are caught at compile time rather
/// than silently disabling downstream replay/analytics filters that match
/// against the value (see `CounterfactualReplay.outlineFirstStrict`).
///
/// `String`-backed and `Codable` so JSON-mode logs and handoff cards
/// round-trip without a schema migration; `CaseIterable` so settings
/// surfaces and the routing-corpus test can enumerate the surface.
///
/// Read boundary policy: legacy `agent_trace_event` rows whose stored
/// string isn't a known case decode to `nil` on `AgentTraceEvent.feature`
/// and bump `event_counters("agent_trace.unknown_intent")` with a logged
/// warning. SQL-side pivots (`pivotByFeature`) keep the raw string —
/// they group by stored value and never go through this enum.
public enum ToolIntent: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case read
    case fetch
    case search
    case outline
    case bundle
    case exec
    case validate
    case explore
    case knowledge
    case embed
    case parse
    case repo
    case session
    case version
    case vision
    case watch
    case web
    case deps
    case pane
}

/// Typed vocabulary for `AgentTraceEvent.result` — the outcome of a tool
/// call. Replaces a primitive `String`. Same compile-time-typo argument
/// as `ToolIntent`: `CounterfactualReplay` matches against `.cached`, the
/// `pivotByResult` chart group-by sees `success` vs `error`, and a typo
/// at any write site silently mis-classifies rows for both.
///
/// Includes an `.unknown` sentinel for legacy rows whose stored string
/// isn't a known case. The result column is NOT NULL on disk, so the
/// typed read path needs a non-nil fallback; `.unknown` makes that
/// fallback explicit (the read path also bumps
/// `event_counters("agent_trace.unknown_result")` with a logged warning).
/// Write sites should never use `.unknown` directly — it exists to
/// represent legacy data we can't classify, not as a "no opinion" choice.
public enum CallResult: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case success
    case error
    case timeout
    case denied
    case cached
    /// Sentinel for legacy DB rows whose stored result string isn't a
    /// known vocabulary value. Not for write-time use.
    case unknown
}
