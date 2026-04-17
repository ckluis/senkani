import Foundation
import Core
import Indexer

// MARK: - BundleComposer
//
// Produces a single budget-bounded markdown document summarizing a
// project. Composes existing primitives (`SymbolIndex`, `DependencyGraph`,
// `KnowledgeStore`, plus optional README content) — does NOT re-index
// anything. Output is deterministic given the same inputs.
//
// Section order is fixed: header → stats → TOC → outlines → deps →
// kb → readme. Truncation always cuts from the tail, so critical
// structural context (file structure, symbols) appears before the
// longer free-text sections (KB understanding, README excerpt).
//
// Secret-safety: any free-text content that originated outside the
// composer's control (README, KB `compiledUnderstanding`) is scanned
// by `SecretDetector.scan` before landing in the document. A repo
// with a committed API key doesn't turn a bundle into an exfiltration
// channel.
//
// Budget: char-count/4 approximates token count (standard rough
// heuristic matching `SymbolIndex.repoMap`). Header notes the
// approximation loudly (Karpathy) so users calibrate instead of
// trusting it as an exact tokenizer estimate.

public enum BundleSection: String, Sendable, CaseIterable, Hashable, Codable {
    case outlines
    case deps
    case kb
    case readme

    /// Canonical ordering (Torvalds / Tufte): breadth axis pinned, so
    /// `include: [kb, outlines]` and `include: [outlines, kb]` yield the
    /// same bundle. Users who want sections omitted tune the set, not the order.
    public static let canonicalOrder: [BundleSection] = [.outlines, .deps, .kb, .readme]
}

/// Output format for `BundleComposer.compose`. Markdown is the default —
/// the JSON variant emits the same content as a stable `BundleDocument`
/// schema for programmatic consumption.
public enum BundleFormat: String, Sendable, CaseIterable, Hashable, Codable {
    case markdown
    case json
}

public struct BundleOptions: Sendable {
    public let projectRoot: String
    /// Budget in estimated tokens (chars ≈ tokens × 4). Header reports
    /// the approximation explicitly — not an exact tokenizer count.
    public let maxTokens: Int
    /// Which sections to include. Default = all four in canonical order.
    public let include: Set<BundleSection>
    /// Generation timestamp (injectable for tests).
    public let now: Date
    /// Max entries to show in the deps "top imported files" section
    /// (Torvalds/Tufte: dep graph is noisy — top-N only).
    public let depsTopN: Int
    /// Max entries to show in the KB "most-mentioned entities" section.
    public let kbTopN: Int

    public init(
        projectRoot: String,
        maxTokens: Int = 20000,
        include: Set<BundleSection> = Set(BundleSection.allCases),
        now: Date = Date(),
        depsTopN: Int = 5,
        kbTopN: Int = 10
    ) {
        self.projectRoot = projectRoot
        self.maxTokens = maxTokens
        self.include = include
        self.now = now
        self.depsTopN = depsTopN
        self.kbTopN = kbTopN
    }
}

public struct BundleInputs: Sendable {
    public let index: SymbolIndex
    public let graph: DependencyGraph?
    public let entities: [KnowledgeEntity]
    public let readme: String?

    public init(
        index: SymbolIndex,
        graph: DependencyGraph? = nil,
        entities: [KnowledgeEntity] = [],
        readme: String? = nil
    ) {
        self.index = index
        self.graph = graph
        self.entities = entities
        self.readme = readme
    }
}

public enum BundleComposer {

    /// Header marker — regex-stable so tests can assert provenance line.
    public static let provenanceMarker = "_Senkani bundle_"

    /// Compose the bundle. Deterministic given inputs. Default format
    /// is markdown; pass `format: .json` for the stable `BundleDocument`
    /// JSON shape.
    public static func compose(
        options: BundleOptions,
        inputs: BundleInputs,
        format: BundleFormat = .markdown
    ) -> String {
        switch format {
        case .markdown: return composeMarkdown(options: options, inputs: inputs)
        case .json:     return composeJSON(options: options, inputs: inputs)
        }
    }

    // MARK: - Markdown

    private static func composeMarkdown(options: BundleOptions, inputs: BundleInputs) -> String {
        var out = ""
        // Char budget = tokens × 4 (documented approximation).
        let charBudget = max(0, options.maxTokens) * 4

        // 1. Header + provenance (always included — one line, minimal cost).
        out += headerLines(options: options, inputs: inputs)

        // 2. Stats — 3 lines, ~200 chars, always fits.
        out += statsLines(inputs: inputs)

        // 3-6. Budgeted sections in canonical order.
        for section in BundleSection.canonicalOrder where options.include.contains(section) {
            let block: String
            switch section {
            case .outlines: block = outlinesSection(inputs: inputs)
            case .deps:     block = depsSection(inputs: inputs, topN: options.depsTopN)
            case .kb:       block = kbSection(inputs: inputs, topN: options.kbTopN)
            case .readme:   block = readmeSection(inputs: inputs)
            }
            // Budget check — if appending this section would overflow,
            // append a truncation marker and stop. Cuts from the tail so
            // higher-priority sections survive.
            if out.count + block.count > charBudget {
                out += "\n\n---\n"
                out += "_Bundle truncated at \(section.rawValue) section — budget (≈\(options.maxTokens) tokens / \(charBudget) chars) exceeded._\n"
                break
            }
            out += block
        }
        return out
    }

    // MARK: - Sections

    private static func headerLines(options: BundleOptions, inputs: BundleInputs) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let projectName = (options.projectRoot as NSString).lastPathComponent
        let idxTime = iso.string(from: inputs.index.generated)
        let now = iso.string(from: options.now)
        var header = ""
        header += "# \(projectName)\n\n"
        header += "\(provenanceMarker) — generated \(now) — budget ≈\(options.maxTokens) tokens (\(options.maxTokens * 4) chars, char/4 approx) — symbol index updated \(idxTime)\n\n"
        return header
    }

    private static func statsLines(inputs: BundleInputs) -> String {
        let fileCount = Set(inputs.index.symbols.map(\.file)).count
        let symbolCount = inputs.index.symbols.count
        let depCount = inputs.graph?.imports.values.reduce(0) { $0 + $1.count } ?? 0
        let entityCount = inputs.entities.count

        var out = "## Stats\n\n"
        out += "- **Files indexed**: \(fileCount)\n"
        out += "- **Symbols**: \(symbolCount)\n"
        out += "- **Import edges**: \(depCount)\n"
        out += "- **KB entities**: \(entityCount)\n\n"
        return out
    }

    private static func outlinesSection(inputs: BundleInputs) -> String {
        // Deterministic: files lex-sorted, symbols within a file by startLine.
        var byFile: [String: [IndexEntry]] = [:]
        for sym in inputs.index.symbols { byFile[sym.file, default: []].append(sym) }
        let sortedFiles = byFile.keys.sorted()

        var out = "## Outlines\n\n"
        if sortedFiles.isEmpty {
            out += "_(no files indexed)_\n\n"
            return out
        }

        for file in sortedFiles {
            let syms = byFile[file]!.sorted { $0.startLine < $1.startLine }
            out += "### \(file)\n\n"
            // Split top-level vs contained.
            var topLevel: [IndexEntry] = []
            var contained: [String: [IndexEntry]] = [:]
            for s in syms {
                if let c = s.container { contained[c, default: []].append(s) }
                else { topLevel.append(s) }
            }
            for s in topLevel {
                out += "- `\(s.kind.rawValue) \(s.name)` — L\(s.startLine)\n"
                if let members = contained[s.name] {
                    for m in members.sorted(by: { $0.startLine < $1.startLine }) {
                        out += "  - `\(m.kind.rawValue) \(m.name)` — L\(m.startLine)\n"
                    }
                }
            }
            out += "\n"
        }
        return out
    }

    private static func depsSection(inputs: BundleInputs, topN: Int) -> String {
        var out = "## Dependency Highlights\n\n"
        guard let graph = inputs.graph, !graph.importedBy.isEmpty else {
            out += "_(no dependency graph available)_\n\n"
            return out
        }

        // Top-N most-imported-by (the hubs of the codebase).
        let ranked = graph.importedBy
            .map { (module: $0.key, count: $0.value.count) }
            .sorted {
                // Primary: count desc. Tie-break: module name asc
                // (determinism over tied counts).
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.module < $1.module
            }
            .prefix(topN)

        if ranked.isEmpty {
            out += "_(no imports recorded)_\n\n"
            return out
        }

        out += "Top \(ranked.count) most-imported-by modules:\n\n"
        out += "| Module | Imported by |\n"
        out += "|---|---|\n"
        for entry in ranked {
            out += "| `\(entry.module)` | \(entry.count) |\n"
        }
        out += "\n"
        return out
    }

    private static func kbSection(inputs: BundleInputs, topN: Int) -> String {
        var out = "## Knowledge Base\n\n"
        guard !inputs.entities.isEmpty else {
            out += "_(no KB entities yet — run a few sessions to populate)_\n\n"
            return out
        }

        // mentionCount desc, tiebreak by name asc — deterministic.
        let top = inputs.entities.sorted {
            if $0.mentionCount != $1.mentionCount {
                return $0.mentionCount > $1.mentionCount
            }
            return $0.name < $1.name
        }.prefix(topN)

        for entity in top {
            out += "### \(entity.name)\n\n"
            out += "- **Type**: \(entity.entityType)\n"
            if let src = entity.sourcePath, !src.isEmpty {
                out += "- **File**: `\(src)`\n"
            }
            out += "- **Mentions**: \(entity.mentionCount)\n"
            if !entity.compiledUnderstanding.isEmpty {
                // Scan for secrets before embedding (Schneier P0).
                let sanitized = SecretDetector.scan(entity.compiledUnderstanding).redacted
                let trimmed = String(sanitized.prefix(400))
                out += "\n\(trimmed)\n"
                if sanitized.count > 400 { out += "_(truncated — see senkani_knowledge for full entity)_\n" }
            }
            out += "\n"
        }
        return out
    }

    private static func readmeSection(inputs: BundleInputs) -> String {
        var out = "## README\n\n"
        guard let readme = inputs.readme, !readme.isEmpty else {
            out += "_(no README at project root)_\n\n"
            return out
        }
        // Scan for secrets (Schneier P0).
        let sanitized = SecretDetector.scan(readme).redacted
        // Cap — a massive README would dominate the bundle.
        let trimmed = String(sanitized.prefix(4000))
        out += trimmed
        if sanitized.count > 4000 {
            out += "\n\n_(README truncated — see the file at the project root for the full text)_\n"
        }
        out += "\n"
        return out
    }

    // MARK: - JSON

    private static func composeJSON(options: BundleOptions, inputs: BundleInputs) -> String {
        let charBudget = max(0, options.maxTokens) * 4
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        var doc = BundleDocument(
            header: jsonHeader(options: options, inputs: inputs),
            stats: jsonStats(inputs: inputs),
            outlines: nil, deps: nil, kb: nil, readme: nil,
            truncated: nil
        )

        // Start with header + stats — always emitted, matching the
        // markdown variant where the header/stats always fit.
        for section in BundleSection.canonicalOrder where options.include.contains(section) {
            let probe = doc
            var candidate = doc
            switch section {
            case .outlines: candidate.outlines = jsonOutlines(inputs: inputs)
            case .deps:     candidate.deps     = jsonDeps(inputs: inputs, topN: options.depsTopN)
            case .kb:       candidate.kb       = jsonKB(inputs: inputs, topN: options.kbTopN)
            case .readme:   candidate.readme   = jsonReadme(inputs: inputs)
            }
            // Budget check: serialize the candidate and compare to the
            // char budget. If over, revert to `probe` and stamp the
            // truncation marker (same tail-cut behavior as markdown).
            if jsonSize(of: candidate, encoder: encoder) > charBudget {
                doc = probe
                doc.truncated = BundleDocument.Truncation(
                    section: section.rawValue,
                    reason: "budget (≈\(options.maxTokens) tokens / \(charBudget) chars) exceeded"
                )
                break
            }
            doc = candidate
        }

        guard let data = try? encoder.encode(doc),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private static func jsonSize(of doc: BundleDocument, encoder: JSONEncoder) -> Int {
        (try? encoder.encode(doc).count) ?? Int.max
    }

    private static func jsonHeader(options: BundleOptions, inputs: BundleInputs) -> BundleDocument.Header {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let projectName = (options.projectRoot as NSString).lastPathComponent
        return BundleDocument.Header(
            projectName: projectName,
            generated: iso.string(from: options.now),
            indexUpdated: iso.string(from: inputs.index.generated),
            maxTokens: options.maxTokens,
            charBudget: options.maxTokens * 4,
            provenance: provenanceMarker
        )
    }

    private static func jsonStats(inputs: BundleInputs) -> BundleDocument.Stats {
        let fileCount = Set(inputs.index.symbols.map(\.file)).count
        let symbolCount = inputs.index.symbols.count
        let depCount = inputs.graph?.imports.values.reduce(0) { $0 + $1.count } ?? 0
        let entityCount = inputs.entities.count
        return BundleDocument.Stats(
            filesIndexed: fileCount,
            symbols: symbolCount,
            importEdges: depCount,
            kbEntities: entityCount
        )
    }

    private static func jsonOutlines(inputs: BundleInputs) -> BundleDocument.Outlines {
        var byFile: [String: [IndexEntry]] = [:]
        for sym in inputs.index.symbols { byFile[sym.file, default: []].append(sym) }
        let sortedFiles = byFile.keys.sorted()

        var files: [BundleDocument.FileOutline] = []
        for file in sortedFiles {
            let syms = byFile[file]!.sorted { $0.startLine < $1.startLine }
            var topLevel: [IndexEntry] = []
            var contained: [String: [IndexEntry]] = [:]
            for s in syms {
                if let c = s.container { contained[c, default: []].append(s) }
                else { topLevel.append(s) }
            }
            let symbols: [BundleDocument.SymbolOutline] = topLevel.map { s in
                let members = (contained[s.name] ?? [])
                    .sorted { $0.startLine < $1.startLine }
                    .map { m in
                        BundleDocument.SymbolOutline(
                            name: m.name, kind: m.kind.rawValue,
                            line: m.startLine, members: []
                        )
                    }
                return BundleDocument.SymbolOutline(
                    name: s.name, kind: s.kind.rawValue,
                    line: s.startLine, members: members
                )
            }
            files.append(BundleDocument.FileOutline(path: file, symbols: symbols))
        }
        return BundleDocument.Outlines(files: files)
    }

    private static func jsonDeps(inputs: BundleInputs, topN: Int) -> BundleDocument.Deps {
        guard let graph = inputs.graph, !graph.importedBy.isEmpty else {
            return BundleDocument.Deps(topImportedBy: [])
        }
        let ranked = graph.importedBy
            .map { (module: $0.key, count: $0.value.count) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.module < $1.module
            }
            .prefix(topN)
            .map { BundleDocument.DepEntry(module: $0.module, importedByCount: $0.count) }
        return BundleDocument.Deps(topImportedBy: Array(ranked))
    }

    private static func jsonKB(inputs: BundleInputs, topN: Int) -> BundleDocument.KnowledgeBase {
        guard !inputs.entities.isEmpty else {
            return BundleDocument.KnowledgeBase(entities: [])
        }
        let top = inputs.entities.sorted {
            if $0.mentionCount != $1.mentionCount {
                return $0.mentionCount > $1.mentionCount
            }
            return $0.name < $1.name
        }.prefix(topN)

        let entities: [BundleDocument.Entity] = top.map { entity in
            var understanding: String? = nil
            var truncated = false
            if !entity.compiledUnderstanding.isEmpty {
                // Scan for secrets before embedding (Schneier P0).
                let sanitized = SecretDetector.scan(entity.compiledUnderstanding).redacted
                truncated = sanitized.count > 400
                understanding = String(sanitized.prefix(400))
            }
            let file = (entity.sourcePath?.isEmpty == false) ? entity.sourcePath : nil
            return BundleDocument.Entity(
                name: entity.name,
                type: entity.entityType,
                file: file,
                mentions: entity.mentionCount,
                understanding: understanding,
                understandingTruncated: truncated
            )
        }
        return BundleDocument.KnowledgeBase(entities: entities)
    }

    private static func jsonReadme(inputs: BundleInputs) -> BundleDocument.Readme {
        guard let readme = inputs.readme, !readme.isEmpty else {
            return BundleDocument.Readme(content: "", truncated: false)
        }
        let sanitized = SecretDetector.scan(readme).redacted
        let trimmed = String(sanitized.prefix(4000))
        return BundleDocument.Readme(content: trimmed, truncated: sanitized.count > 4000)
    }
}

// MARK: - README discovery helper

extension BundleComposer {
    /// Locate and read a README at `projectRoot`. Returns nil if none
    /// exists. Tries common capitalizations, bounded at 64 KB — a runaway
    /// README shouldn't OOM the composer.
    public static func readme(at projectRoot: String) -> String? {
        let candidates = ["README.md", "README", "Readme.md", "readme.md"]
        for name in candidates {
            let path = projectRoot + "/" + name
            guard FileManager.default.fileExists(atPath: path) else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path),
                                       options: [.mappedIfSafe]) else { continue }
            let truncated = data.prefix(65_536)
            if let s = String(data: truncated, encoding: .utf8) { return s }
        }
        return nil
    }
}
