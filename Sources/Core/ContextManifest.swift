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
// U.10b. U.10a-2 layers the secret gate on top — see
// `Sources/Bundle/BundleSecretGate.swift` for the `composeManifestGated`
// wrapper, refusal-without-override semantics, and the chained
// `bundle.secret.allow` / `bundle.dispatch` audit-row writers.

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
/// hits. `flagged` = at least one pattern matched and the item is
/// held for the U.10a-2 gate's override decision (`--allow-secrets` /
/// `allow_secrets:true`). `redacted` is reserved for downstream
/// callers that ship scrubbed content alongside the manifest; the
/// in-tree producer paths emit `clean` or `flagged` only.
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

// MARK: - U.10b mode inputs
//
// Three pre-resolved input types feed the U.10b modes. The CLI/MCP
// layer performs the I/O (file read for slice, `git diff` shell-out
// for diff-only, Gemma async call for summary) and passes the
// resolved data into `ManifestOptions`. The producer
// (`BundleComposer.composeManifest`) stays synchronous + deterministic.

/// Pre-resolved file slice for `slice` mode. `content` is the actual
/// extracted text (CLI reads the file at `path` and slices by `range`).
/// `tokens_actual` in the emitted manifest item is `content.count / 4`.
public struct SliceRequest: Sendable, Equatable {
    public let path: String
    public let range: ContextRange
    public let content: String
    public init(path: String, range: ContextRange, content: String) {
        self.path = path
        self.range = range
        self.content = content
    }
}

/// Selector for `diff-only` mode. Mirrors the four `git diff`
/// invocations: unstaged (`git diff`), staged (`git diff --cached`),
/// branch (`git diff <ref>...HEAD`), and range (`git diff <a>..<b>`).
public enum DiffSelector: Sendable, Equatable, Hashable {
    case unstaged
    case staged
    case branch(String)
    case range(String, String)

    /// Stable string form for the manifest's `inclusion_reason` field
    /// and CLI/MCP parsing. Round-trippable via `init(rawValue:)`.
    public var rawValue: String {
        switch self {
        case .unstaged: return "unstaged"
        case .staged: return "staged"
        case .branch(let ref): return "branch:\(ref)"
        case .range(let a, let b): return "range:\(a)..\(b)"
        }
    }

    /// Parse a selector from CLI `--diff <value>` / MCP `diff: "<value>"`.
    /// Returns nil for malformed input.
    public init?(rawValue: String) {
        if rawValue == "unstaged" { self = .unstaged; return }
        if rawValue == "staged" { self = .staged; return }
        if rawValue.hasPrefix("branch:") {
            let ref = String(rawValue.dropFirst("branch:".count))
            guard !ref.isEmpty else { return nil }
            self = .branch(ref)
            return
        }
        if rawValue.hasPrefix("range:") {
            let body = rawValue.dropFirst("range:".count)
            // Match the canonical git two-dot range — we don't try to
            // accept three-dot here because `diff <a>..<b>` and
            // `diff <a>...<b>` mean materially different things and
            // we don't want to guess.
            let parts = body.components(separatedBy: "..")
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
            self = .range(parts[0], parts[1])
            return
        }
        return nil
    }
}

/// Pre-resolved diff for `diff-only` mode. `perFileDiff` is a map of
/// file path → diff hunks (one entry per file the selector touched).
/// CLI/MCP shells out to `git diff <selector>` and parses the patch
/// into per-file blocks; the producer emits one manifest item per
/// entry, with `lane: .diff`, `mode: .diffOnly`, and
/// `inclusion_reason: "diff_<selector.rawValue>"`.
public struct DiffRequest: Sendable, Equatable {
    public let selector: DiffSelector
    public let perFileDiff: [String: String]
    public init(selector: DiffSelector, perFileDiff: [String: String]) {
        self.selector = selector
        self.perFileDiff = perFileDiff
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
