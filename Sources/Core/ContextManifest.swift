import Foundation

// MARK: - ContextManifest
//
// The U.10 manifest shape. A `ContextManifest` is the review surface
// produced by `BundleComposer.composeManifest()` and exposed via
// `senkani bundle --preview` (CLI) + `senkani_bundle preview:true`
// (MCP). It enumerates exactly which sources, ranges, and modes a
// bundle dispatch *would* include — so callers can audit the plan
// before materializing the bundle body.
//
// The shape is a STABLE CONTRACT — once shipped, renaming a
// `ContextManifestItem` field, lane, or mode is a breaking change
// for any consumer that decodes this JSON. Add new fields as
// optionals; add new lanes/modes only at the tail of their enums.
//
// U.10a-1 ships the schema, the 8 first-class lanes, the 4 trivial
// modes, and the `inclusion_reason: "mode-pending-u10b"` placeholder
// for the 3 modes (`slice`, `diff-only`, `summary`) that ship in
// U.10b. The `sensitivity` field is populated by U.10a-1's pre-scan
// but the hard refusal path + `--allow-secrets` override + chained
// `bundle.secret.allow` / `bundle.dispatch` audit rows are U.10a-2's
// scope.

/// The eight first-class lanes in the manifest vocabulary. Lane
/// membership is the schema-level axis: every consumer can switch
/// exhaustively on `ContextLane` without an "unknown" arm. Adding a
/// new lane is a breaking change.
public enum ContextLane: String, Sendable, CaseIterable, Hashable, Codable {
    case file
    case diff
    case codemap
    case symbol
    case knowledge
    case runtime
    case manual
    case artifact
}

/// The seven mode kinds across U.10a + U.10b. The 4 trivial modes
/// (`full`, `codemap`, `artifactStubbed`, `excludedWithReason`) ship
/// in U.10a-1; the 3 pending modes (`slice`, `diffOnly`, `summary`)
/// are reserved schema slots that emit a stub item with
/// `inclusion_reason: "mode-pending-u10b"` until U.10b lands.
public enum ContextMode: String, Sendable, CaseIterable, Hashable, Codable {
    case full
    case codemap
    case artifactStubbed = "artifact-stubbed"
    case excludedWithReason = "excluded-with-reason"
    case slice
    case diffOnly = "diff-only"
    case summary

    /// Modes shipped in U.10a-1. Modes outside this set emit a stub.
    public static let trivial: Set<ContextMode> = [
        .full, .codemap, .artifactStubbed, .excludedWithReason,
    ]
}

/// Per-item freshness signal. `fresh` = both estimate and content are
/// current. `staleEstimate` = the char/4 estimate diverges from
/// `tokens_actual` by more than ±20 %. `staleIndex` = the underlying
/// symbol/dep index is older than the source file mtime.
public enum ContextFreshness: String, Sendable, CaseIterable, Hashable, Codable {
    case fresh
    case staleEstimate = "stale_estimate"
    case staleIndex = "stale_index"
}

/// Per-item sensitivity classification. `clean` = no secret-detector
/// hits. `redacted` = content was scrubbed by `SecretDetector.scan`
/// before being attached. `flagged` = at least one pattern matched
/// and the item is held for the U.10a-2 gate decision.
public enum ContextSensitivity: String, Sendable, CaseIterable, Hashable, Codable {
    case clean
    case redacted
    case flagged
}

/// Line-range pair for items that reference a slice of a file.
public struct ContextRange: Codable, Sendable, Equatable, Hashable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// A single manifest entry. All keys map to fixed JSON names; the
/// `CodingKeys` block is the contract surface. Optional fields use
/// nil to indicate "not applicable" (vs empty string which would
/// still encode as a JSON key).
public struct ContextManifestItem: Codable, Sendable, Equatable {
    public var id: String
    public var lane: ContextLane
    public var path: String?
    public var range: ContextRange?
    public var mode: ContextMode
    public var tokensEstimated: Int
    public var tokensActual: Int
    public var freshness: ContextFreshness
    public var sensitivity: ContextSensitivity
    public var inclusionReason: String
    public var toolId: String?

    public init(
        id: String,
        lane: ContextLane,
        path: String? = nil,
        range: ContextRange? = nil,
        mode: ContextMode,
        tokensEstimated: Int,
        tokensActual: Int,
        freshness: ContextFreshness = .fresh,
        sensitivity: ContextSensitivity = .clean,
        inclusionReason: String,
        toolId: String? = nil
    ) {
        self.id = id
        self.lane = lane
        self.path = path
        self.range = range
        self.mode = mode
        self.tokensEstimated = tokensEstimated
        self.tokensActual = tokensActual
        self.freshness = freshness
        self.sensitivity = sensitivity
        self.inclusionReason = inclusionReason
        self.toolId = toolId
    }

    enum CodingKeys: String, CodingKey {
        case id
        case lane
        case path
        case range
        case mode
        case tokensEstimated = "tokens_estimated"
        case tokensActual = "tokens_actual"
        case freshness
        case sensitivity
        case inclusionReason = "inclusion_reason"
        case toolId = "tool_id"
    }
}

/// Top-level manifest document. Items appear in lane-then-original-
/// order; counts surface for analytics + the U.10a-2 dispatch row.
public struct ContextManifest: Codable, Sendable, Equatable {
    public var generated: String
    public var projectRoot: String
    public var modesRequested: [ContextMode]
    public var lanesRequested: [ContextLane]
    public var items: [ContextManifestItem]
    public var counts: Counts

    public struct Counts: Codable, Sendable, Equatable {
        public var total: Int
        public var perLane: [String: Int]
        public var perMode: [String: Int]
        public var tokensEstimatedTotal: Int

        public init(
            total: Int,
            perLane: [String: Int],
            perMode: [String: Int],
            tokensEstimatedTotal: Int
        ) {
            self.total = total
            self.perLane = perLane
            self.perMode = perMode
            self.tokensEstimatedTotal = tokensEstimatedTotal
        }

        enum CodingKeys: String, CodingKey {
            case total
            case perLane = "per_lane"
            case perMode = "per_mode"
            case tokensEstimatedTotal = "tokens_estimated_total"
        }
    }

    public init(
        generated: String,
        projectRoot: String,
        modesRequested: [ContextMode],
        lanesRequested: [ContextLane],
        items: [ContextManifestItem],
        counts: Counts
    ) {
        self.generated = generated
        self.projectRoot = projectRoot
        self.modesRequested = modesRequested
        self.lanesRequested = lanesRequested
        self.items = items
        self.counts = counts
    }

    enum CodingKeys: String, CodingKey {
        case generated
        case projectRoot = "project_root"
        case modesRequested = "modes_requested"
        case lanesRequested = "lanes_requested"
        case items
        case counts
    }
}
