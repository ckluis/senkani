import Testing
import Foundation

/// CI drift guard: every `docs/reference/panes/*.html` detail page's nav
/// sidebar ⇄ the canonical pane list in `docs/reference/panes.html`.
///
/// Companion to `PanesReferenceDriftTests` (which guards `panes.html` ⇄ the
/// `PaneType` enum). That suite keeps the *index* honest; this one keeps the
/// 21 *detail-page* sidebars honest, closing the second drift loop: the
/// per-page `<aside class="wiki-nav">` "Pane types (N)" groups had silently
/// forked into a stale 17-pane shape and a correct-but-Settings-less 20-pane
/// shape. `tools/sync-pane-sidebars.py` regenerates every sidebar from
/// `panes.html`; this test fails the build the moment any page diverges.
///
/// For EVERY detail page it asserts:
///   • the set of pane slugs linked inside the aside's "Pane types" group ==
///     the canonical card-slug set parsed from `panes.html`,
///   • the `<h4>Pane types (N)</h4>` count N == the card count, and
///   • a Settings link (`panes/settings.html`) is present in the aside.
///
/// The parse is scoped to the `<aside class="wiki-nav">...</aside>` block, and
/// within it to the "Pane types" group, so the breadcrumb / body "All pane
/// types" links and the Reference-group `panes.html` index link are never
/// counted. It reuses `PanesReferenceDriftTests.cardSlugs(in:)` /
/// `readFile(_:)` so the canonical source stays singular.
@Suite("PaneDetailSidebarDrift — panes/*.html sidebars ⇄ panes.html")
struct PaneDetailSidebarDriftTests {

    static let detailDirRelPath = "docs/reference/panes"

    private static func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // .../Tests/SenkaniTests
            .deletingLastPathComponent()  // .../Tests
            .deletingLastPathComponent()  // repo root
    }

    /// Absolute URLs of every `docs/reference/panes/*.html` detail page.
    static func detailPageURLs() throws -> [URL] {
        let dir = repoRoot().appendingPathComponent(detailDirRelPath)
        let entries = try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        return entries
            .filter { $0.pathExtension == "html" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The inner text of the `<aside class="wiki-nav" ...>...</aside>` block,
    /// or nil if the page has no such block.
    static func asideBlock(in html: String) -> Substring? {
        guard let openRange = html.range(of: #"<aside class="wiki-nav""#),
              let close = html.range(
                of: "</aside>", range: openRange.upperBound..<html.endIndex)
        else { return nil }
        return html[openRange.lowerBound..<close.upperBound]
    }

    /// Slugs from `<li><a href="..panes/<slug>.html">` links WITHIN the aside's
    /// "Pane types" group only — scoped from the `Pane types` heading to the
    /// next `<h4>` (the "Panels & overlays" group) so the Settings link and the
    /// Reference-group `panes.html` index link are excluded.
    static func paneTypesGroupSlugs(in aside: Substring) -> Set<String> {
        guard let groupStart = aside.range(of: "Pane types (") else { return [] }
        // End the group at the next <h4 (the Panels & overlays group), or the
        // end of the aside if there is none.
        let after = aside[groupStart.upperBound...]
        let groupEnd = after.range(of: "<h4")?.lowerBound ?? after.endIndex
        let group = String(after[after.startIndex..<groupEnd])

        let pattern = #"href="[^"]*panes/([a-z0-9-]+)\.html""#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(group.startIndex..., in: group)
        var slugs: Set<String> = []
        regex.enumerateMatches(in: group, range: range) { match, _, _ in
            guard let m = match,
                  let r = Range(m.range(at: 1), in: group) else { return }
            slugs.insert(String(group[r]))
        }
        return slugs
    }

    /// The integer N in `<h4>Pane types (N)</h4>`, or nil.
    static func paneTypesHeadingCount(in aside: Substring) -> Int? {
        let s = String(aside)
        let pattern = #"Pane types \((\d+)\)"#
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(s.startIndex..., in: s)
        guard let m = regex.firstMatch(in: s, range: range),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Int(s[r])
    }

    @Test("every panes/*.html detail-page sidebar matches the canonical 20-pane list")
    func everyDetailSidebarMatchesCanonicalList() throws {
        let indexHTML = try PanesReferenceDriftTests.readFile(
            PanesReferenceDriftTests.panesHTMLRelPath)
        let canonicalSlugs = Set(PanesReferenceDriftTests.cardSlugs(in: indexHTML))
        let canonicalCount = canonicalSlugs.count

        #expect(!canonicalSlugs.isEmpty,
                "Parsed no canonical card slugs from panes.html — parser or page changed shape")

        let pages = try Self.detailPageURLs()
        #expect(!pages.isEmpty,
                "Found no detail pages under \(Self.detailDirRelPath) — glob or layout changed")

        for page in pages {
            let name = page.lastPathComponent
            let html = try String(contentsOf: page, encoding: .utf8)

            guard let aside = Self.asideBlock(in: html) else {
                Issue.record("\(name): no <aside class=\"wiki-nav\"> block found")
                continue
            }

            let pageSlugs = Self.paneTypesGroupSlugs(in: aside)
            let onlyOnPage = pageSlugs.subtracting(canonicalSlugs).sorted()
            let missingOnPage = canonicalSlugs.subtracting(pageSlugs).sorted()

            #expect(pageSlugs == canonicalSlugs,
                    "\(name): Pane types group drifted from panes.html. Extra on page: \(onlyOnPage). Missing on page: \(missingOnPage).")

            let heading = Self.paneTypesHeadingCount(in: aside)
            #expect(heading == canonicalCount,
                    "\(name): heading 'Pane types (\(heading.map(String.init) ?? "?"))' disagrees with canonical card count \(canonicalCount).")

            #expect(aside.range(of: "panes/settings.html") != nil,
                    "\(name): sidebar is missing the Panels & overlays Settings link (panes/settings.html).")
        }
    }
}
