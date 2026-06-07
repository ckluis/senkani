import Testing
import Foundation

/// CI drift guard: `docs/reference/panes.html` ⇄ `PaneType` enum.
///
/// Root-cause automation for the `website-panes-reference-out-of-sync-with-
/// panetype-enum` defect class. The original symptom (the reference page
/// drifting from the shipped pane set) kept recurring because nothing in the
/// build diffed the two — it was caught only by a manual audit. This suite
/// closes that loop: it parses the card slugs out of `panes.html` and the
/// cases out of `PaneType` (read off disk via `#filePath`, since the
/// `SenkaniApp` executable target is not importable into tests — same trick
/// `DocsTruthGuardTests` uses), applies the one documented slug↔raw-value
/// mapping, and FAILS the build the moment the two sets diverge or the
/// on-page count stops matching the card count.
///
/// Two documented exceptions to "slug == kebab-case(rawValue)":
///   • `schedules`        (slug) ⇄ `scheduleManager`     (PaneType)
///   • `served-requests`  (slug) ⇄ `openAIServedRequests`(PaneType)
/// Both live in `slugToRawValueOverrides` below; every other pane derives by
/// the mechanical kebab↔camel rule.
@Suite("PanesReferenceDrift — panes.html ⇄ PaneType enum")
struct PanesReferenceDriftTests {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/SenkaniTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    // Non-private so the gallery parity suite (PaneGalleryTests, same test
    // module) can reuse these parsers + paths instead of re-deriving them.
    static let panesHTMLRelPath = "docs/reference/panes.html"
    static let paneTypeRelPath = "SenkaniApp/Models/PaneModel.swift"

    /// Slugs whose camelCase `PaneType.rawValue` is NOT the mechanical
    /// camel-case of the kebab slug. Keep this the single home for every
    /// documented exception.
    private static let slugToRawValueOverrides: [String: String] = [
        "schedules": "scheduleManager",
        "served-requests": "openAIServedRequests",
    ]

    // MARK: - Parsing

    static func readFile(_ relPath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Card slugs from `panes.html`, in document order, e.g. `agent-timeline`.
    /// Matches the `<a class="card" href=".../panes/<slug>.html">` anchors.
    static func cardSlugs(in html: String) -> [String] {
        let pattern = #"class="card"\s+href="[^"]*panes/([a-z0-9-]+)\.html""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        var slugs: [String] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: html) else { return }
            slugs.append(String(html[r]))
        }
        return slugs
    }

    /// The integer in the `<h4>Pane types (N)</h4>` nav heading, or nil.
    static func headingCount(in html: String) -> Int? {
        let pattern = #"Pane types \((\d+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return Int(html[r])
    }

    /// The integer in `content="All N senkani workspace pane types."`, or nil.
    static func metaDescriptionCount(in html: String) -> Int? {
        let pattern = #"name="description"\s+content="All (\d+) "#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return Int(html[r])
    }

    /// `PaneType` raw values parsed from `PaneModel.swift`. Reads only the
    /// `enum PaneType: String, CaseIterable { ... }` block so unrelated enums
    /// in the file (BudgetState, ProcessState, …) are never picked up.
    static func paneTypeRawValues(in source: String) -> [String] {
        guard let enumStart = source.range(of: "enum PaneType: String") else {
            return []
        }
        // Walk from the enum's opening brace to its matching close brace.
        let afterDecl = source[enumStart.upperBound...]
        guard let braceOpen = afterDecl.firstIndex(of: "{") else { return [] }
        var depth = 0
        var bodyEnd = source.endIndex
        var i = braceOpen
        while i < source.endIndex {
            let c = source[i]
            if c == "{" { depth += 1 }
            else if c == "}" {
                depth -= 1
                if depth == 0 { bodyEnd = i; break }
            }
            i = source.index(after: i)
        }
        let body = source[source.index(after: braceOpen)..<bodyEnd]
        // `case foo` — one identifier per case (PaneType has no associated values).
        let pattern = #"(?m)^\s*case\s+([A-Za-z][A-Za-z0-9]*)\s*$"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let bodyStr = String(body)
        let range = NSRange(bodyStr.startIndex..., in: bodyStr)
        var cases: [String] = []
        regex.enumerateMatches(in: bodyStr, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: bodyStr) else { return }
            cases.append(String(bodyStr[r]))
        }
        return cases
    }

    // MARK: - Mapping

    /// Mechanical kebab-slug → camelCase rawValue (e.g. `agent-timeline`
    /// → `agentTimeline`), overridden by `slugToRawValueOverrides`.
    static func expectedRawValue(forSlug slug: String) -> String {
        if let override = slugToRawValueOverrides[slug] { return override }
        let parts = slug.split(separator: "-").map(String.init)
        guard let head = parts.first else { return slug }
        let tail = parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return ([head] + tail).joined()
    }

    // MARK: - Tests

    @Test("panes.html card slugs map 1:1 onto the PaneType enum (no drift)")
    func cardSlugsMatchPaneTypeEnum() throws {
        let html = try Self.readFile(Self.panesHTMLRelPath)
        let source = try Self.readFile(Self.paneTypeRelPath)

        let slugs = Self.cardSlugs(in: html)
        let rawValues = Self.paneTypeRawValues(in: source)

        #expect(!slugs.isEmpty,
                "Parsed no card slugs from \(Self.panesHTMLRelPath) — parser or page changed shape")
        #expect(!rawValues.isEmpty,
                "Parsed no cases from PaneType in \(Self.paneTypeRelPath) — parser or enum changed shape")

        let mappedFromSlugs = Set(slugs.map(Self.expectedRawValue(forSlug:)))
        let enumValues = Set(rawValues)

        let onlyInDocs = mappedFromSlugs.subtracting(enumValues).sorted()
        let onlyInEnum = enumValues.subtracting(mappedFromSlugs).sorted()

        #expect(onlyInDocs.isEmpty,
                "panes.html documents panes with no PaneType case (after mapping): \(onlyInDocs)")
        #expect(onlyInEnum.isEmpty,
                "PaneType ships cases with no panes.html card (after mapping): \(onlyInEnum)")
    }

    @Test("panes.html count surfaces (meta + heading) match the card count")
    func onPageCountsMatchCardCount() throws {
        let html = try Self.readFile(Self.panesHTMLRelPath)
        let cardCount = Self.cardSlugs(in: html).count

        let heading = Self.headingCount(in: html)
        let meta = Self.metaDescriptionCount(in: html)

        #expect(heading == cardCount,
                "Nav heading 'Pane types (\(heading.map(String.init) ?? "?"))' disagrees with \(cardCount) cards")
        #expect(meta == cardCount,
                "meta description count \(meta.map(String.init) ?? "?") disagrees with \(cardCount) cards")
    }

    // MARK: - Parser self-tests (red on introduced drift)

    @Test("mapping handles both documented overrides and mechanical kebab↔camel")
    func mappingCoversOverridesAndMechanicalCase() {
        #expect(Self.expectedRawValue(forSlug: "schedules") == "scheduleManager")
        #expect(Self.expectedRawValue(forSlug: "served-requests") == "openAIServedRequests")
        #expect(Self.expectedRawValue(forSlug: "agent-timeline") == "agentTimeline")
        #expect(Self.expectedRawValue(forSlug: "terminal") == "terminal")
        #expect(Self.expectedRawValue(forSlug: "html-preview") == "htmlPreview")
    }

    @Test("drift check goes red when a card slug has no PaneType case")
    func driftIsDetectedForExtraCard() throws {
        let source = try Self.readFile(Self.paneTypeRelPath)
        let enumValues = Set(Self.paneTypeRawValues(in: source))
        // Simulate panes.html gaining a card the enum never added.
        let driftedSlugs = ["terminal", "ghost-pane"]
        let mapped = Set(driftedSlugs.map(Self.expectedRawValue(forSlug:)))
        let onlyInDocs = mapped.subtracting(enumValues)
        #expect(onlyInDocs.contains("ghostPane"),
                "A card with no matching PaneType must surface as drift, not pass silently")
    }
}
