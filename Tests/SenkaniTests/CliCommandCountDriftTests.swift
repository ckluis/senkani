import Testing
import Foundation

/// CI drift guard: `docs/reference/cli.html` command-count surfaces ⇄
/// rendered sidebar command entries.
///
/// Root-cause automation for the same defect class `PanesReferenceDriftTests`
/// closes for `panes.html`: a count baked into the page (the sidebar
/// `<h4>CLI commands (N)</h4>` heading + the `all N senkani CLI commands`
/// meta description) silently drifts from the actual number of command
/// entries the moment someone adds or removes a command and forgets to bump
/// a counter. This suite parses all three numbers and FAILS the build the
/// instant any two disagree.
///
/// The sidebar lists commands two ways inside the "CLI commands"
/// `wiki-nav-group`:
///   • LINKED:     `<li><a href="...cli/senkani-X.html"><code>senkani X</code></a></li>`
///   • NON-LINKED: `<li><code>senkani X</code></li>`  (serve/vault/monitor/…)
/// Both are real command entries and both are counted. The parse is SCOPED
/// to that one nav group so unrelated `<code>senkani …</code>` fragments in
/// the lede / listing descriptions / other nav groups are never counted.
@Suite("CliCommandCountDrift — cli.html command-count surfaces ⇄ sidebar entries")
struct CliCommandCountDriftTests {

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/SenkaniTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    static let cliHTMLRelPath = "docs/reference/cli.html"

    // MARK: - Parsing

    static func readFile(_ relPath: String) throws -> String {
        let url = repoRoot().appendingPathComponent(relPath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The `<div class="wiki-nav-group">…</div>` block whose `<h4>` heading
    /// starts with "CLI commands". Returns the block's inner HTML (from the
    /// heading to the group's closing `</div>`), or nil if not found. Scoping
    /// the entry parse to this block is what keeps `senkani …` mentions in the
    /// lede or listing descriptions out of the count.
    static func cliCommandsNavGroup(in html: String) -> String? {
        // Find the heading, then walk back to the enclosing wiki-nav-group's
        // opening tag and forward through balanced <div>…</div> to its close.
        guard let headingRange = html.range(of: "CLI commands (") else { return nil }
        // Opening <div ...> of the group: the last `<div` before the heading.
        guard let groupOpen = html.range(
            of: "<div class=\"wiki-nav-group\">",
            options: .backwards,
            range: html.startIndex..<headingRange.lowerBound
        ) else { return nil }

        // Balance <div>/</div> from groupOpen to find the matching close.
        var depth = 0
        var idx = groupOpen.lowerBound
        var groupEnd: String.Index? = nil
        while idx < html.endIndex {
            if html[idx...].hasPrefix("<div") {
                depth += 1
                idx = html.index(idx, offsetBy: 4)
                continue
            }
            if html[idx...].hasPrefix("</div>") {
                depth -= 1
                if depth == 0 {
                    groupEnd = html.index(idx, offsetBy: 6)
                    break
                }
                idx = html.index(idx, offsetBy: 6)
                continue
            }
            idx = html.index(after: idx)
        }
        guard let end = groupEnd else { return nil }
        return String(html[groupOpen.lowerBound..<end])
    }

    /// Command names rendered as sidebar entries within the CLI commands nav
    /// group, in document order. Counts BOTH linked
    /// (`<li><a …><code>senkani X</code></a></li>`) and non-linked
    /// (`<li><code>senkani X</code></li>`) entries — the regex keys on the
    /// `<code>senkani X</code>` payload, which both forms share, so a single
    /// pattern captures every entry regardless of the surrounding `<a>`.
    /// Captures the FIRST word after `senkani ` (e.g. `monitor`,
    /// `ml-eval`) so multi-word display names collapse to their command.
    static func sidebarCommands(in groupHTML: String) -> [String] {
        let pattern = #"<li>(?:<a [^>]*>)?<code>senkani ([a-z][a-z0-9-]*)</code>"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(groupHTML.startIndex..., in: groupHTML)
        var commands: [String] = []
        regex.enumerateMatches(in: groupHTML, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: groupHTML) else { return }
            commands.append(String(groupHTML[r]))
        }
        return commands
    }

    /// The integer in the `<h4>CLI commands (N)</h4>` nav heading, or nil.
    static func headingCount(in html: String) -> Int? {
        let pattern = #"CLI commands \((\d+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return Int(html[r])
    }

    /// The integer in `content="Reference for all N senkani CLI commands."`,
    /// or nil.
    static func metaDescriptionCount(in html: String) -> Int? {
        let pattern = #"all (\d+) senkani CLI commands"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        guard let m = regex.firstMatch(in: html, range: range),
              let r = Range(m.range(at: 1), in: html) else { return nil }
        return Int(html[r])
    }

    /// Every `cli/senkani-<name>.html` href referenced anywhere in cli.html
    /// (sidebar links + listing-row anchors), de-duplicated.
    static func referencedDetailPages(in html: String) -> [String] {
        let pattern = #"(cli/senkani-[a-z0-9-]+\.html)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(html.startIndex..., in: html)
        var paths: Set<String> = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: html) else { return }
            paths.insert(String(html[r]))
        }
        return paths.sorted()
    }

    // MARK: - Tests

    @Test("cli.html heading == meta == rendered sidebar command count (no drift)")
    func countSurfacesAgree() throws {
        let html = try Self.readFile(Self.cliHTMLRelPath)

        guard let group = Self.cliCommandsNavGroup(in: html) else {
            Issue.record("Could not locate the 'CLI commands' wiki-nav-group in \(Self.cliHTMLRelPath) — parser or page changed shape")
            return
        }

        let commands = Self.sidebarCommands(in: group)
        let entryCount = commands.count
        let heading = Self.headingCount(in: html)
        let meta = Self.metaDescriptionCount(in: html)

        #expect(entryCount > 0,
                "Parsed no command entries from the CLI commands nav group — parser or page changed shape")

        // Fail loud, naming all three numbers + the parsed command set.
        let detail = """
        heading=\(heading.map(String.init) ?? "nil"), \
        meta=\(meta.map(String.init) ?? "nil"), \
        rendered entries=\(entryCount) \
        [\(commands.joined(separator: ", "))]
        """

        #expect(heading == entryCount,
                "Sidebar <h4>CLI commands (\(heading.map(String.init) ?? "?"))> disagrees with \(entryCount) rendered entries. \(detail)")
        #expect(meta == entryCount,
                "Meta 'all \(meta.map(String.init) ?? "?") senkani CLI commands' disagrees with \(entryCount) rendered entries. \(detail)")
        #expect(heading == meta,
                "Heading count \(heading.map(String.init) ?? "?") disagrees with meta count \(meta.map(String.init) ?? "?"). \(detail)")

        // `monitor` is a known command entry — guards against the scope
        // accidentally dropping the non-linked tail of the list.
        #expect(commands.contains("monitor"),
                "Rendered sidebar command set must include 'monitor'. Parsed: [\(commands.joined(separator: ", "))]")
    }

    @Test("every cli.html senkani-*.html link points at a file that exists on disk")
    func detailPageLinksResolve() throws {
        let html = try Self.readFile(Self.cliHTMLRelPath)
        let referenced = Self.referencedDetailPages(in: html)

        // cli.html lives at docs/reference/cli.html, so `cli/senkani-X.html`
        // resolves to docs/reference/cli/senkani-X.html.
        let referenceDir = Self.repoRoot().appendingPathComponent("docs/reference")
        var missing: [String] = []
        for rel in referenced {
            let url = referenceDir.appendingPathComponent(rel)
            if !FileManager.default.fileExists(atPath: url.path) {
                missing.append(rel)
            }
        }

        #expect(missing.isEmpty,
                "cli.html links to detail pages that do not exist on disk: \(missing). De-link them (drop the <a href> and keep the <code> entry) or create the page.")
    }
}
