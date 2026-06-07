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

    // U.10b — pre-resolved mode inputs. The CLI/MCP layer performs I/O
    // (file read for slice, `git diff` shell for diff-only, Gemma async
    // for summary) and passes the resolved data here so the producer
    // stays synchronous and deterministic. When a mode is requested
    // but its corresponding input is nil, the producer emits no items
    // for that mode (no more `mode-pending-u10b` stubs).

    /// Pre-resolved slice for `slice` mode. CLI `--slice <path>:<a>:<b>`,
    /// MCP `slice:"<path>:<a>:<b>"`. When present and `.slice` is in
    /// `modes`, the producer emits one file-lane item.
    public let slice: SliceRequest?

    /// Pre-resolved diff for `diff-only` mode. CLI `--diff <selector>`,
    /// MCP `diff:"<selector>"`. When present and `.diffOnly` is in
    /// `modes`, the producer emits one diff-lane item per file in
    /// `perFileDiff`.
    public let diff: DiffRequest?

    /// Pre-resolved per-entity summaries for `summary` mode. Keyed by
    /// `KnowledgeEntity.name`. CLI/MCP populate via
    /// `GemmaRationaleRewriter.summarize(content:budgetTokens:)`; when
    /// an entry is missing, the producer falls back to the entity's
    /// `compiledUnderstanding`. When neither is present (no entry +
    /// empty understanding), the item emits with
    /// `inclusion_reason: "summary_unavailable"`.
    public let entitySummaries: [String: String]?

    /// Token budget used to flag `summary` items whose
    /// `tokens_actual` diverges from `tokens_estimated`. Defaults to
    /// 200 — matches a "compress this entity into ~200 tokens" budget.
    public let summaryBudgetTokens: Int

    public init(
        projectRoot: String,
        modes: Set<ContextMode> = ContextMode.trivial,
        lanes: Set<ContextLane> = Set(ContextLane.allCases),
        now: Date = Date(),
        toolId: String? = nil,
        slice: SliceRequest? = nil,
        diff: DiffRequest? = nil,
        entitySummaries: [String: String]? = nil,
        summaryBudgetTokens: Int = 200
    ) {
        self.projectRoot = projectRoot
        self.modes = modes
        self.lanes = lanes
        self.now = now
        self.toolId = toolId
        self.slice = slice
        self.diff = diff
        self.entitySummaries = entitySummaries
        self.summaryBudgetTokens = summaryBudgetTokens
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
                // U.10b — slice mode is attached to the file lane.
                if options.modes.contains(.slice), let slice = options.slice {
                    items.append(sliceItem(slice: slice, options: options))
                }
            case .diff:
                // U.10b — diff-only mode emits per-file items here.
                if options.modes.contains(.diffOnly), let diff = options.diff {
                    items.append(contentsOf: diffItems(diff: diff, options: options))
                }
            case .codemap:
                items.append(contentsOf: codemapLaneItems(inputs: inputs, options: options))
            case .symbol:
                items.append(contentsOf: symbolLaneItems(inputs: inputs, options: options))
            case .knowledge:
                items.append(contentsOf: knowledgeLaneItems(inputs: inputs, options: options))
                // U.10b — summary mode emits an alternate per-entity
                // representation alongside the full knowledge items.
                if options.modes.contains(.summary) {
                    items.append(contentsOf: summaryItems(inputs: inputs, options: options))
                }
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

    // MARK: - U.10b mode helpers

    /// `slice` mode — emit one file-lane item carrying the pre-resolved
    /// slice. `tokens_estimated` reflects the requested line span (end -
    /// start + 1, in token estimate), `tokens_actual` is the slice's
    /// actual char/4 — so an unexpectedly long line flips
    /// `freshness: stale_estimate`.
    private static func sliceItem(
        slice: SliceRequest, options: ManifestOptions
    ) -> ContextManifestItem {
        // Estimate: assume ~40 chars per line of code at the heuristic
        // boundary. Doesn't need to be exact — the freshness check
        // surfaces meaningful drift only.
        let lineCount = max(1, slice.range.end - slice.range.start + 1)
        let estimated = estimateTokens(lineCount * 40)
        let actual = estimateTokens(slice.content.count)
        let scan = SecretDetector.scan(slice.content)
        let sensitivity: ContextSensitivity = scan.patterns.isEmpty ? .clean : .flagged
        return ContextManifestItem(
            id: "slice:\(slice.path)#\(slice.range.start)-\(slice.range.end)",
            lane: .file,
            path: slice.path,
            range: slice.range,
            mode: .slice,
            tokensEstimated: estimated,
            tokensActual: actual,
            freshness: freshnessFor(estimated: estimated, actual: actual),
            sensitivity: sensitivity,
            inclusionReason: "slice_\(slice.range.start)_\(slice.range.end)",
            toolId: options.toolId
        )
    }

    /// `diff-only` mode — one item per file in the resolved diff.
    /// `inclusion_reason` carries the selector verbatim (e.g.
    /// `diff_branch:main`) so reviewers can replay the same git command.
    private static func diffItems(
        diff: DiffRequest, options: ManifestOptions
    ) -> [ContextManifestItem] {
        let reason = "diff_\(diff.selector.rawValue)"
        return diff.perFileDiff.keys.sorted().map { path in
            let body = diff.perFileDiff[path] ?? ""
            let scan = SecretDetector.scan(body)
            // Diff content is *especially* high-risk for secrets — the
            // gate's existing flagged-item check fires on these the
            // same way it does for the file lane.
            let sensitivity: ContextSensitivity = scan.patterns.isEmpty ? .clean : .flagged
            let actual = estimateTokens(scan.redacted.count)
            return ContextManifestItem(
                id: "diff:\(path)",
                lane: .diff,
                path: path,
                mode: .diffOnly,
                tokensEstimated: actual,
                tokensActual: actual,
                sensitivity: sensitivity,
                inclusionReason: reason,
                toolId: options.toolId
            )
        }
    }

    /// `summary` mode — one item per knowledge entity, content is either
    /// the pre-resolved Gemma summary (when present in
    /// `options.entitySummaries`), the entity's compiledUnderstanding
    /// (KB fallback), or absent — emitting
    /// `inclusion_reason: "summary_unavailable"`.
    private static func summaryItems(
        inputs: BundleInputs, options: ManifestOptions
    ) -> [ContextManifestItem] {
        let sorted = inputs.entities.sorted {
            if $0.mentionCount != $1.mentionCount { return $0.mentionCount > $1.mentionCount }
            return $0.name < $1.name
        }
        let budgetEstimate = max(0, options.summaryBudgetTokens)
        return sorted.map { entity in
            let preResolved = options.entitySummaries?[entity.name]
            let kbFallback = entity.compiledUnderstanding
            let summary = preResolved ?? (kbFallback.isEmpty ? nil : kbFallback)
            let reason: String
            let actualContent: String
            switch (preResolved, summary) {
            case (.some, _):
                reason = "summary_gemma"
                actualContent = preResolved!
            case (.none, .some):
                reason = "summary_kb_fallback"
                actualContent = kbFallback
            case (.none, .none):
                reason = "summary_unavailable"
                actualContent = ""
            }
            let scan = SecretDetector.scan(actualContent)
            let sensitivity: ContextSensitivity = scan.patterns.isEmpty ? .clean : .flagged
            let actual = estimateTokens(scan.redacted.count)
            return ContextManifestItem(
                id: "summary:\(entity.name)",
                lane: .knowledge,
                path: entity.sourcePath,
                mode: .summary,
                tokensEstimated: budgetEstimate,
                tokensActual: actual,
                freshness: freshnessFor(estimated: budgetEstimate, actual: actual),
                sensitivity: sensitivity,
                inclusionReason: reason,
                toolId: options.toolId
            )
        }
    }

    /// Freshness rule: `tokens_actual` divergence from
    /// `tokens_estimated` by more than ±20 % flips `.staleEstimate`.
    /// Zero-estimate items are treated as fresh when actual is also
    /// zero, stale otherwise (a non-empty body with no budget is by
    /// definition off).
    private static func freshnessFor(
        estimated: Int, actual: Int
    ) -> ContextFreshness {
        if estimated == 0 {
            return actual == 0 ? .fresh : .staleEstimate
        }
        let delta = abs(actual - estimated)
        // delta / estimated > 0.20  ↔  delta * 5 > estimated
        return delta * 5 > estimated ? .staleEstimate : .fresh
    }
}
