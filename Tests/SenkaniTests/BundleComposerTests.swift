import Testing
import Foundation
@testable import Core
@testable import Indexer
@testable import Bundle

// MARK: - Fixture helpers

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)  // 2024-04-17T12:00:00Z

private func makeIndex(
    projectRoot: String = "/tmp/bundle-fixture",
    files: [String: [IndexEntry]]
) -> SymbolIndex {
    var idx = SymbolIndex()
    idx.projectRoot = projectRoot
    idx.generated = fixedDate
    for (_, entries) in files {
        idx.symbols.append(contentsOf: entries)
    }
    return idx
}

private func makeEntry(
    _ name: String, _ kind: SymbolKind, file: String,
    line: Int, container: String? = nil
) -> IndexEntry {
    IndexEntry(name: name, kind: kind, file: file, startLine: line,
               container: container)
}

private func standardFixtureInputs() -> BundleInputs {
    let entries: [String: [IndexEntry]] = [
        "Sources/Foo.swift": [
            makeEntry("Foo", .class, file: "Sources/Foo.swift", line: 10),
            makeEntry("bar", .method, file: "Sources/Foo.swift", line: 15, container: "Foo"),
        ],
        "Sources/Bar.swift": [
            makeEntry("Bar", .struct, file: "Sources/Bar.swift", line: 5),
        ],
        "Tests/FooTests.swift": [
            makeEntry("FooTests", .class, file: "Tests/FooTests.swift", line: 3),
        ],
    ]
    let idx = makeIndex(files: entries)

    let graph = DependencyGraph(
        imports: [
            "Sources/Foo.swift": ["Foundation", "Sources/Bar.swift"],
            "Sources/Bar.swift": ["Foundation"],
        ],
        importedBy: [
            "Sources/Bar.swift": ["Sources/Foo.swift"],
            "Foundation": ["Sources/Foo.swift", "Sources/Bar.swift"],
        ],
        projectRoot: idx.projectRoot,
        generated: fixedDate
    )

    let entities = [
        KnowledgeEntity(
            id: 1, name: "Foo", entityType: "class",
            sourcePath: "Sources/Foo.swift",
            markdownPath: ".senkani/knowledge/Foo.md",
            compiledUnderstanding: "Foo is the main domain type.",
            mentionCount: 7,
            createdAt: fixedDate, modifiedAt: fixedDate
        ),
        KnowledgeEntity(
            id: 2, name: "Bar", entityType: "struct",
            sourcePath: "Sources/Bar.swift",
            markdownPath: ".senkani/knowledge/Bar.md",
            compiledUnderstanding: "Bar holds configuration.",
            mentionCount: 3,
            createdAt: fixedDate, modifiedAt: fixedDate
        ),
    ]

    return BundleInputs(
        index: idx, graph: graph,
        entities: entities, readme: "# Project\n\nHello, world.\n")
}

// MARK: - Determinism

@Suite("BundleComposer determinism (Karpathy + Torvalds)")
struct BundleDeterminismTests {

    @Test func sameInputsProduceByteIdenticalOutput() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(
            projectRoot: inputs.index.projectRoot,
            maxTokens: 20_000,
            now: fixedDate
        )
        let a = BundleComposer.compose(options: opts, inputs: inputs)
        let b = BundleComposer.compose(options: opts, inputs: inputs)
        #expect(a == b, "BundleComposer must produce byte-identical output for identical inputs")
    }

    @Test func outlineSectionIsLexicographicByPath() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        let barPos = doc.range(of: "Sources/Bar.swift")!.lowerBound
        let fooPos = doc.range(of: "Sources/Foo.swift")!.lowerBound
        let testsPos = doc.range(of: "Tests/FooTests.swift")!.lowerBound
        #expect(barPos < fooPos, "Sources/Bar.swift must precede Sources/Foo.swift (lex order)")
        #expect(fooPos < testsPos, "Sources/ paths must precede Tests/ paths (lex order)")
    }

    @Test func includeSetOrderDoesNotAffectOutput() {
        let inputs = standardFixtureInputs()
        let optsA = BundleOptions(
            projectRoot: inputs.index.projectRoot,
            maxTokens: 20_000,
            include: [.kb, .outlines, .deps, .readme],
            now: fixedDate
        )
        let optsB = BundleOptions(
            projectRoot: inputs.index.projectRoot,
            maxTokens: 20_000,
            include: [.readme, .kb, .deps, .outlines],
            now: fixedDate
        )
        let a = BundleComposer.compose(options: optsA, inputs: inputs)
        let b = BundleComposer.compose(options: optsB, inputs: inputs)
        #expect(a == b, "Canonical section order must be preserved regardless of include-set order")
    }
}

// MARK: - Section order (Tufte)

@Suite("BundleComposer section order (Tufte)")
struct BundleSectionOrderTests {

    @Test func canonicalOrderIsOutlinesDepsKBReadme() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)

        let outlinesPos = doc.range(of: "## Outlines")!.lowerBound
        let depsPos     = doc.range(of: "## Dependency Highlights")!.lowerBound
        let kbPos       = doc.range(of: "## Knowledge Base")!.lowerBound
        let readmePos   = doc.range(of: "## README")!.lowerBound

        #expect(outlinesPos < depsPos, "Outlines section must come before Deps")
        #expect(depsPos < kbPos,       "Deps section must come before KB")
        #expect(kbPos < readmePos,     "KB section must come before README")
    }

    @Test func headerLineIsFirst() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        // First line is "# <projectName>"
        #expect(doc.hasPrefix("# "))
        // Second non-empty line carries the provenance marker.
        #expect(doc.contains(BundleComposer.provenanceMarker))
    }
}

// MARK: - Budget enforcement (Karpathy)

@Suite("BundleComposer budget enforcement (Karpathy)")
struct BundleBudgetTests {

    /// Construct a fat fixture so the budget has something to truncate.
    private func fatInputs() -> BundleInputs {
        var entries: [IndexEntry] = []
        for i in 0..<200 {
            let file = String(format: "Sources/Gen%03d.swift", i)
            entries.append(makeEntry("Class\(i)", .class, file: file, line: 1))
            for j in 0..<20 {
                entries.append(makeEntry("method\(j)", .method,
                                         file: file, line: 5 + j,
                                         container: "Class\(i)"))
            }
        }
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/fat-bundle"
        idx.generated = fixedDate
        idx.symbols = entries
        return BundleInputs(index: idx)
    }

    @Test func tinyBudgetTruncatesEarly() {
        let inputs = fatInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 1000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        // 1000 tokens ≈ 4000 chars — with some slack for the truncation
        // notice. 4500 bytes is a reasonable ceiling for the composer's
        // overhead on top of the ceiling.
        #expect(doc.utf8.count <= 4500,
            "budget of 1000 tokens should keep bundle under ~4500 chars; got \(doc.utf8.count)")
        #expect(doc.contains("truncated"),
            "over-budget bundle must include a truncation notice")
    }

    @Test func generousBudgetIncludesAllSections() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        #expect(doc.contains("## Outlines"))
        #expect(doc.contains("## Dependency Highlights"))
        #expect(doc.contains("## Knowledge Base"))
        #expect(doc.contains("## README"))
        #expect(!doc.contains("Bundle truncated"))
    }

    @Test func includeSetControlsWhichSectionsEmit() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(
            projectRoot: inputs.index.projectRoot,
            maxTokens: 20_000,
            include: [.outlines, .deps],
            now: fixedDate
        )
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        #expect(doc.contains("## Outlines"))
        #expect(doc.contains("## Dependency Highlights"))
        #expect(!doc.contains("## Knowledge Base"))
        #expect(!doc.contains("## README"))
    }
}

// MARK: - Schneier — secret scanning

@Suite("BundleComposer secret scanning (Schneier P0)")
struct BundleSecretScanTests {

    // Seed a KB entity with a fake API key shape that SecretDetector
    // recognizes. The composer must redact before embedding.
    @Test func redactsSecretsInEmbeddedKBUnderstanding() {
        let anthropicKey = "sk-ant-api03-" + String(repeating: "A", count: 85)
        let entity = KnowledgeEntity(
            id: 1, name: "Auth", entityType: "class",
            markdownPath: ".senkani/knowledge/Auth.md",
            compiledUnderstanding: "Handles auth. Secret: \(anthropicKey)",
            mentionCount: 5,
            createdAt: fixedDate, modifiedAt: fixedDate
        )
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/bundle-secrets"
        idx.generated = fixedDate
        let inputs = BundleInputs(index: idx, entities: [entity])
        let opts = BundleOptions(projectRoot: idx.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        #expect(!doc.contains(anthropicKey),
            "raw Anthropic API key must not survive into the bundle")
        #expect(doc.contains("[REDACTED") || doc.contains("redacted"),
            "redaction marker should appear where the key was")
    }

    @Test func redactsSecretsInEmbeddedReadme() {
        let bearer = "Bearer sk-ant-api03-" + String(repeating: "B", count: 85)
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/bundle-readme-secrets"
        idx.generated = fixedDate
        let readme = "# Project\n\nAuth header: \(bearer)\n"
        let inputs = BundleInputs(index: idx, readme: readme)
        let opts = BundleOptions(projectRoot: idx.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        #expect(!doc.contains(bearer),
            "raw bearer token from README must not land in bundle")
    }
}

// MARK: - Edge cases (Bach)

@Suite("BundleComposer edge cases (Bach)")
struct BundleEdgeCaseTests {

    @Test func emptyProjectProducesMinimalValidBundle() {
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/empty-bundle"
        idx.generated = fixedDate
        let inputs = BundleInputs(index: idx)
        let opts = BundleOptions(projectRoot: idx.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        // Header + stats + empty section placeholders — should still be
        // a valid markdown document.
        #expect(doc.hasPrefix("# empty-bundle"))
        #expect(doc.contains("Files indexed**: 0"))
        #expect(doc.contains("## Outlines"))
        #expect(doc.contains("(no files indexed)") || doc.contains("(no")) // either composer variant
    }

    @Test func kbEntitiesLimitedToKbTopN() {
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/many-entities"
        idx.generated = fixedDate
        var entities: [KnowledgeEntity] = []
        for i in 0..<50 {
            entities.append(KnowledgeEntity(
                id: Int64(i + 1),
                name: String(format: "E%03d", i),
                entityType: "class",
                markdownPath: "",
                mentionCount: 50 - i,
                createdAt: fixedDate, modifiedAt: fixedDate
            ))
        }
        let inputs = BundleInputs(index: idx, entities: entities)
        let opts = BundleOptions(
            projectRoot: idx.projectRoot,
            maxTokens: 20_000,
            now: fixedDate,
            kbTopN: 5
        )
        let doc = BundleComposer.compose(options: opts, inputs: inputs)

        // First 5 entities (highest mentionCount) should appear.
        for i in 0..<5 {
            let name = String(format: "E%03d", i)
            #expect(doc.contains("### \(name)"),
                "top-5 entity \(name) should appear in bundle")
        }
        // 6th should not — we capped at 5.
        let excluded = String(format: "E%03d", 5)
        #expect(!doc.contains("### \(excluded)"),
            "kbTopN=5 means entity #6 (\(excluded)) must NOT appear")
    }

    @Test func depsHighlightsLimitedToDepsTopN() {
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/many-deps"
        idx.generated = fixedDate
        var importedBy: [String: [String]] = [:]
        for i in 0..<30 {
            let key = String(format: "Module%02d", i)
            importedBy[key] = Array(repeating: "f.swift", count: 30 - i)
        }
        let graph = DependencyGraph(importedBy: importedBy,
                                    projectRoot: idx.projectRoot,
                                    generated: fixedDate)
        let inputs = BundleInputs(index: idx, graph: graph)
        let opts = BundleOptions(
            projectRoot: idx.projectRoot,
            maxTokens: 20_000,
            now: fixedDate,
            depsTopN: 3
        )
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        // Top 3 by count should appear — Module00 (30), Module01 (29), Module02 (28).
        #expect(doc.contains("`Module00`"))
        #expect(doc.contains("`Module01`"))
        #expect(doc.contains("`Module02`"))
        // Module03 should NOT appear.
        #expect(!doc.contains("`Module03`"))
    }

    @Test func readmeDiscoveryFindsReadmeMd() throws {
        let root = NSTemporaryDirectory() + "bundle-readme-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "# Found me".write(toFile: root + "/README.md",
                               atomically: true, encoding: .utf8)
        let readme = BundleComposer.readme(at: root)
        #expect(readme == "# Found me")
    }

    @Test func readmeDiscoveryReturnsNilWhenMissing() {
        let root = NSTemporaryDirectory() + "bundle-no-readme-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(BundleComposer.readme(at: root) == nil)
    }

    @Test func provenanceHeaderIncludesTimestamps() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let doc = BundleComposer.compose(options: opts, inputs: inputs)
        // Header should include both the generation timestamp AND the
        // index's last-updated timestamp (Kleppmann P1).
        #expect(doc.contains("generated"),
            "provenance line must include a 'generated' timestamp")
        #expect(doc.contains("symbol index updated"),
            "provenance line must include the index's last-updated timestamp")
        #expect(doc.contains("budget"),
            "provenance line must report the budget so sharers know the scale")
    }
}

// MARK: - JSON format (Lauret schema contract + Bach round-trip)

@Suite("BundleComposer JSON format")
struct BundleJSONFormatTests {

    @Test func markdownIsDefaultFormat() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let implicit = BundleComposer.compose(options: opts, inputs: inputs)
        let explicit = BundleComposer.compose(options: opts, inputs: inputs, format: .markdown)
        #expect(implicit == explicit,
            "compose() without format must be byte-identical to compose(..., format: .markdown)")
        // And the markdown output must still start with a markdown header
        // (guards against an accidental format-dispatch bug).
        #expect(implicit.hasPrefix("# "))
    }

    @Test func jsonOutputRoundTripsThroughJSONDecoder() throws {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let raw = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        let data = Data(raw.utf8)
        let decoded = try JSONDecoder().decode(BundleDocument.self, from: data)
        #expect(decoded.header.projectName == "bundle-fixture")
        #expect(decoded.header.provenance == BundleComposer.provenanceMarker)
        #expect(decoded.stats.filesIndexed == 3)
        #expect(decoded.stats.symbols == 4)
        #expect(decoded.outlines != nil)
        #expect(decoded.deps != nil)
        #expect(decoded.kb != nil)
        #expect(decoded.readme != nil)
        #expect(decoded.truncated == nil,
            "generous budget must not trip truncation")
    }

    @Test func jsonFixturePinsShape() throws {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let raw = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        let decoded = try JSONDecoder().decode(BundleDocument.self, from: Data(raw.utf8))

        // Outlines — lex-sorted files, Bar.swift first.
        let files = decoded.outlines!.files
        #expect(files.count == 3)
        #expect(files[0].path == "Sources/Bar.swift")
        #expect(files[1].path == "Sources/Foo.swift")
        #expect(files[2].path == "Tests/FooTests.swift")

        // Foo.swift has top-level class Foo with one method `bar` nested.
        let foo = files[1]
        #expect(foo.symbols.count == 1)
        #expect(foo.symbols[0].name == "Foo")
        #expect(foo.symbols[0].kind == "class")
        #expect(foo.symbols[0].members.count == 1)
        #expect(foo.symbols[0].members[0].name == "bar")
        #expect(foo.symbols[0].members[0].kind == "method")

        // Deps — Foundation (2) precedes Sources/Bar.swift (1). Tie-break
        // by module name; here counts differ so order is by count desc.
        let deps = decoded.deps!.topImportedBy
        #expect(deps.count == 2)
        #expect(deps[0].module == "Foundation")
        #expect(deps[0].importedByCount == 2)
        #expect(deps[1].module == "Sources/Bar.swift")

        // KB — mentionCount desc: Foo (7) precedes Bar (3).
        let kb = decoded.kb!.entities
        #expect(kb.count == 2)
        #expect(kb[0].name == "Foo")
        #expect(kb[0].mentions == 7)
        #expect(kb[0].understanding == "Foo is the main domain type.")
        #expect(kb[0].understandingTruncated == false)
        #expect(kb[1].name == "Bar")

        // README content arrives intact for the tiny fixture.
        #expect(decoded.readme!.content == "# Project\n\nHello, world.\n")
        #expect(decoded.readme!.truncated == false)
    }

    @Test func jsonOutputIsDeterministic() {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let a = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        let b = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        #expect(a == b, "JSON output must be byte-identical for identical inputs")
        // Sorted keys: "charBudget" precedes "generated" precedes "indexUpdated"…
        let cbPos = a.range(of: "\"charBudget\"")!.lowerBound
        let genPos = a.range(of: "\"generated\"")!.lowerBound
        #expect(cbPos < genPos,
            "JSONEncoder.sortedKeys must emit keys in lexicographic order")
    }

    @Test func jsonRedactsSecretsInKBAndReadme() throws {
        let anthropicKey = "sk-ant-api03-" + String(repeating: "A", count: 85)
        let bearer = "Bearer sk-ant-api03-" + String(repeating: "B", count: 85)
        let entity = KnowledgeEntity(
            id: 1, name: "Auth", entityType: "class",
            markdownPath: ".senkani/knowledge/Auth.md",
            compiledUnderstanding: "Handles auth. Secret: \(anthropicKey)",
            mentionCount: 5,
            createdAt: fixedDate, modifiedAt: fixedDate
        )
        var idx = SymbolIndex()
        idx.projectRoot = "/tmp/bundle-json-secrets"
        idx.generated = fixedDate
        let readme = "# Project\n\nAuth header: \(bearer)\n"
        let inputs = BundleInputs(index: idx, entities: [entity], readme: readme)
        let opts = BundleOptions(projectRoot: idx.projectRoot,
                                 maxTokens: 20_000, now: fixedDate)
        let raw = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        #expect(!raw.contains(anthropicKey),
            "raw Anthropic API key must not survive into the JSON bundle")
        #expect(!raw.contains(bearer),
            "bearer token from README must not survive into JSON bundle")
        let decoded = try JSONDecoder().decode(BundleDocument.self, from: Data(raw.utf8))
        #expect(decoded.kb!.entities[0].understanding?.contains("REDACTED") == true
                || decoded.kb!.entities[0].understanding?.contains("redacted") == true,
            "KB understanding must retain a redaction marker where the key was")
    }

    @Test func jsonIncludeSetOmitsExcludedSectionsAsNil() throws {
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(
            projectRoot: inputs.index.projectRoot,
            maxTokens: 20_000,
            include: [.outlines, .readme],
            now: fixedDate
        )
        let raw = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        let decoded = try JSONDecoder().decode(BundleDocument.self, from: Data(raw.utf8))
        #expect(decoded.outlines != nil)
        #expect(decoded.readme != nil)
        #expect(decoded.deps == nil,
            "sections omitted via include-set must be nil, not empty")
        #expect(decoded.kb == nil)
        #expect(decoded.truncated == nil)
    }

    @Test func jsonTinyBudgetTripsTruncation() throws {
        // Tiny budget — header + stats alone already approach it, so the
        // first section (outlines) should push us past and trigger the
        // truncation path.
        let inputs = standardFixtureInputs()
        let opts = BundleOptions(projectRoot: inputs.index.projectRoot,
                                 maxTokens: 100, now: fixedDate)
        let raw = BundleComposer.compose(options: opts, inputs: inputs, format: .json)
        let decoded = try JSONDecoder().decode(BundleDocument.self, from: Data(raw.utf8))
        #expect(decoded.truncated != nil,
            "tiny budget must produce a populated `truncated` block")
        #expect(decoded.truncated!.section == "outlines",
            "outlines section should be the first to overflow the 100-token budget")
    }
}
