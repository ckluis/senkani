import Foundation
import Core
import Indexer

// MARK: - BundleComposer.composeManifest
//
// U.10a-1: the review surface. Produces a `ContextManifest` from
// the same `BundleInputs` the body composer reads, but emits a flat
// list of `ContextManifestItem` entries instead of a budget-bounded
// document. Callers (CLI `--preview`, MCP `preview:true`) consume
// the manifest to audit what a dispatch *would* include.
//
// U.10a-1 covers the 4 trivial modes (full, codemap, artifact-stubbed,
// excluded-with-reason). The 3 pending modes (slice, diff-only,
// summary) emit a single stub item per pending-mode request with
// `inclusion_reason: "mode-pending-u10b"` so the surface is forward-
// compatible without crashing.
//
// The U.10a-2 secret gate layers on top of this producer in
// `BundleSecretGate.swift` — items whose free-text content hits
// `SecretDetector.scan` carry `sensitivity: .flagged`, and the gate's
// `composeManifestGated()` wrapper refuses to emit unless the caller
// passes `allowSecrets: true`. The chained `bundle.secret.allow` /
// `bundle.dispatch` audit-row writes live in the gate file too.

public struct ManifestOptions: Sendable {
    public let projectRoot: String
    public let modes: Set<ContextMode>
    public let lanes: Set<ContextLane>
    public let now: Date
    /// Optional caller-attribution for U.7 CapabilityBridge integration
    /// when that ships. Forward-compatible: callers that don't know
    /// their tool_id leave nil.
    public let toolId: String?

    public init(
        projectRoot: String,
        modes: Set<ContextMode> = ContextMode.trivial,
        lanes: Set<ContextLane> = Set(ContextLane.allCases),
        now: Date = Date(),
        toolId: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.modes = modes
        self.lanes = lanes
        self.now = now
        self.toolId = toolId
    }
}

extension BundleComposer {

    /// Compose a review-only `ContextManifest`. Deterministic given
    /// inputs: items are ordered by lane (per `ContextLane.allCases`),
    /// then by stable per-lane order (lex-sorted paths, original
    /// entity order, etc.).
    public static func composeManifest(
        options: ManifestOptions,
        inputs: BundleInputs
    ) -> ContextManifest {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        var items: [ContextManifestItem] = []

        // Lane production. The default lane set is all 8; callers
        // narrow via `--lanes` / `lanes:`. Each lane emits items only
        // when (a) the lane is requested AND (b) inputs have content
        // OR the lane has a reserved-stub contract.
        for lane in ContextLane.allCases where options.lanes.contains(lane) {
            switch lane {
            case .file:
                items.append(contentsOf: fileLaneItems(inputs: inputs, options: options))
            case .diff:
                // No diff data plumbed in U.10a-1. Diff lane sees real
                // items in U.10b when `diff-only` mode ships.
                break
            case .codemap:
                items.append(contentsOf: codemapLaneItems(inputs: inputs, options: options))
            case .symbol:
                items.append(contentsOf: symbolLaneItems(inputs: inputs, options: options))
            case .knowledge:
                items.append(contentsOf: knowledgeLaneItems(inputs: inputs, options: options))
            case .runtime:
                // No runtime artifacts plumbed in U.10a-1.
                break
            case .manual:
                // No manual notes plumbed in U.10a-1.
                break
            case .artifact:
                // V.9a reserved. Emit one marker item so consumers can
                // see the lane is recognised but pending.
                items.append(ContextManifestItem(
                    id: "artifact:reserved",
                    lane: .artifact,
                    mode: .artifactStubbed,
                    tokensEstimated: 0,
                    tokensActual: 0,
                    inclusionReason: "v9-pending",
                    toolId: options.toolId
                ))
            }
        }

        // Pending-mode stubs. When a caller explicitly requests a
        // U.10b-pending mode, emit ONE stub per pending mode so the
        // request shape is forward-compatible — crashing on "not yet
        // implemented" would force callers to feature-detect.
        for mode in [ContextMode.slice, .diffOnly, .summary]
        where options.modes.contains(mode) {
            items.append(ContextManifestItem(
                id: "mode-stub:\(mode.rawValue)",
                lane: stubLane(for: mode),
                mode: mode,
                tokensEstimated: 0,
                tokensActual: 0,
                inclusionReason: "mode-pending-u10b",
                toolId: options.toolId
            ))
        }

        let counts = buildCounts(items: items)

        // Modes/lanes requested fields preserve insertion order via
        // allCases enumeration (deterministic) intersected with the
        // requested sets.
        let modesRequested = ContextMode.allCases.filter { options.modes.contains($0) }
        let lanesRequested = ContextLane.allCases.filter { options.lanes.contains($0) }

        return ContextManifest(
            generated: iso.string(from: options.now),
            projectRoot: (options.projectRoot as NSString).lastPathComponent,
            modesRequested: modesRequested,
            lanesRequested: lanesRequested,
            items: items,
            counts: counts
        )
    }

    /// Render a manifest as JSON string. Stable key ordering (sorted)
    /// makes the parity test between CLI and MCP a byte-equal compare.
    public static func renderManifestJSON(_ manifest: ContextManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(manifest),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    // MARK: - Lane helpers

    private static func fileLaneItems(
        inputs: BundleInputs, options: ManifestOptions
    ) -> [ContextManifestItem] {
        guard let readme = inputs.readme, !readme.isEmpty else { return [] }
        // The README is the canonical `file` lane content for U.10a-1
        // (BundleComposer already discovers and redacts it; this just
        // exposes the same source as a manifest item).
        let mode: ContextMode = options.modes.contains(.full) ? .full : .excludedWithReason
        let scan = SecretDetector.scan(readme)
        let estimated = estimateTokens(scan.redacted.count)
        // U.10a-2 gate semantics: a SecretDetector hit means the
        // underlying source carried a secret pattern, so the item is
        // *flagged* — held for the gate's override decision. The body
        // composer's own redaction still runs downstream; the manifest's
        // job is to surface "would I have shipped a secret-bearing
        // source?" before the body is materialized.
        let sensitivity: ContextSensitivity = scan.patterns.isEmpty ? .clean : .flagged
        return [ContextManifestItem(
            id: "file:README",
            lane: .file,
            path: "README.md",
            mode: mode,
            tokensEstimated: estimated,
            tokensActual: estimated,
            sensitivity: sensitivity,
            inclusionReason: mode == .full ? "readme-included" : "mode-not-requested",
            toolId: options.toolId
        )]
    }

    private static func codemapLaneItems(
        inputs: BundleInputs, options: ManifestOptions
    ) -> [ContextManifestItem] {
        // One item per file in the index, mode .codemap, tokens
        // estimated from the outline character count.
        var byFile: [String: [IndexEntry]] = [:]
        for sym in inputs.index.symbols { byFile[sym.file, default: []].append(sym) }
        let sortedFiles = byFile.keys.sorted()

        let mode: ContextMode = options.modes.contains(.codemap) ? .codemap : .excludedWithReason
        var items: [ContextManifestItem] = []
        for file in sortedFiles {
            let outlineChars = byFile[file]!.reduce(0) {
                $0 + $1.name.count + $1.kind.rawValue.count + 10  // approx per-symbol overhead
            }
            let estimated = estimateTokens(outlineChars)
            items.append(ContextManifestItem(
                id: "codemap:\(file)",
                lane: .codemap,
                path: file,
                mode: mode,
                tokensEstimated: estimated,
                tokensActual: estimated,
                inclusionReason: mode == .codemap ? "outline-available" : "mode-not-requested",
                toolId: options.toolId
            ))
        }
        return items
    }

    private static func symbolLaneItems(
        inputs: BundleInputs, options: ManifestOptions
    ) -> [ContextManifestItem] {
        // One item per top-level symbol, mode .codemap (a symbol-lane
        // request is "show me each symbol's outline as its own item").
        // Container'd symbols are folded under their parent in the
        // codemap lane; the symbol lane emits per-top-level only to
        // keep U.10a-1 cardinality bounded.
        let mode: ContextMode = options.modes.contains(.codemap) ? .codemap : .excludedWithReason
        let topLevel = inputs.index.symbols
            .filter { $0.container == nil }
            .sorted {
                if $0.file != $1.file { return $0.file < $1.file }
                return $0.startLine < $1.startLine
            }
        return topLevel.map { sym in
            let estimated = estimateTokens(sym.name.count + sym.kind.rawValue.count + 20)
            return ContextManifestItem(
                id: "symbol:\(sym.file)#\(sym.name)",
                lane: .symbol,
                path: sym.file,
                range: ContextRange(start: sym.startLine, end: sym.startLine),
                mode: mode,
                tokensEstimated: estimated,
                tokensActual: estimated,
                inclusionReason: mode == .codemap ? "top-level-symbol" : "mode-not-requested",
                toolId: options.toolId
            )
        }
    }

    private static func knowledgeLaneItems(
        inputs: BundleInputs, options: ManifestOptions
    ) -> [ContextManifestItem] {
        // One item per knowledge entity, mode .full, content scanned
        // for secrets and sensitivity classified.
        let mode: ContextMode = options.modes.contains(.full) ? .full : .excludedWithReason
        let sorted = inputs.entities.sorted {
            if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
            return $0.name < $1.name
        }
        return sorted.map { entity in
            let content = entity.compiledUnderstanding
            let scan = SecretDetector.scan(content)
            let estimated = estimateTokens(scan.redacted.count)
            // U.10a-2 gate semantics — see fileLaneItems for the rationale.
            let sensitivity: ContextSensitivity = scan.patterns.isEmpty ? .clean : .flagged
            return ContextManifestItem(
                id: "knowledge:\(entity.name)",
                lane: .knowledge,
                path: entity.sourcePath,
                mode: mode,
                tokensEstimated: estimated,
                tokensActual: estimated,
                sensitivity: sensitivity,
                inclusionReason: mode == .full ? "kb-entity" : "mode-not-requested",
                toolId: options.toolId
            )
        }
    }

    // MARK: - Counts + helpers

    private static func buildCounts(items: [ContextManifestItem]) -> ContextManifest.Counts {
        var perLane: [String: Int] = [:]
        var perMode: [String: Int] = [:]
        var totalEstimated = 0
        for item in items {
            perLane[item.lane.rawValue, default: 0] += 1
            perMode[item.mode.rawValue, default: 0] += 1
            totalEstimated += item.tokensEstimated
        }
        return ContextManifest.Counts(
            total: items.count,
            perLane: perLane,
            perMode: perMode,
            tokensEstimatedTotal: totalEstimated
        )
    }

    /// char/4 → token estimate, matching the bundle-body heuristic.
    /// Documented as approximate; mirrors the existing BundleComposer
    /// note in the header line.
    private static func estimateTokens(_ chars: Int) -> Int {
        max(0, chars / 4)
    }

    /// Pending-mode stubs need a lane to attach to. The natural lane
    /// for each pending mode: slice → file, diff-only → diff,
    /// summary → knowledge. Consumers can filter by lane *or* mode.
    private static func stubLane(for mode: ContextMode) -> ContextLane {
        switch mode {
        case .slice: return .file
        case .diffOnly: return .diff
        case .summary: return .knowledge
        default: return .file
        }
    }
}
