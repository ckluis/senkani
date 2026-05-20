import Testing
import Foundation
@testable import Core

/// U.2a-2a contract tests for `CompletenessAxis.evaluate`. Three assertions
/// per measurement (`title_meta` / `internal_links_resolve` / `img_alt`);
/// one test exercises the all-pass shape and one isolating each individual
/// violation.
@Suite("CompletenessAxis — U.2a-2a evaluator")
struct CompletenessAxisTests {

    private static func goodImage(_ src: String) -> CompletenessMeasurement.ImageElement {
        CompletenessMeasurement.ImageElement(src: src, alt: "alt for \(src)")
    }

    private static func goodLink(_ href: String) -> CompletenessMeasurement.InternalLink {
        CompletenessMeasurement.InternalLink(href: href, statusCode: 200)
    }

    @Test("evaluate covers all-pass + each-isolated-violation across the 3 assertions")
    func evaluateBranches() throws {
        // Branch 1 — all-pass synthetic measurement.
        do {
            let m = CompletenessMeasurement(
                title: "Senkani — local-first AI compression",
                metaDescription: "A token compression layer that keeps your context warm.",
                internalLinks: [Self.goodLink("https://example.com/about"), Self.goodLink("https://example.com/docs")],
                images: [Self.goodImage("hero.png"), Self.goodImage("diagram.svg")]
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let allPassed = r.allSatisfy { $0.passed }
            let allAdvisoryNil = r.allSatisfy { $0.advisory == nil }
            #expect(r.count == 3)
            #expect(allPassed,
                    "all three assertions must pass on the synthetic all-pass measurement; got \(r.map { ($0.assertionId, $0.passed) })")
            #expect(allAdvisoryNil)
        }

        // Branch 2 — title empty → title_meta fails; other two still pass.
        do {
            let m = CompletenessMeasurement(
                title: "  ",  // whitespace-only counts as empty after trim
                metaDescription: "Meta present.",
                internalLinks: [Self.goodLink("https://example.com/x")],
                images: [Self.goodImage("ok.png")]
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let tm = r.first { $0.assertionId == "completeness.title_meta" }!
            let links = r.first { $0.assertionId == "completeness.internal_links_resolve" }!
            let alt = r.first { $0.assertionId == "completeness.img_alt" }!
            #expect(tm.passed == false)
            #expect(tm.advisory!.contains("<title>"))
            #expect(links.passed == true)
            #expect(alt.passed == true)
        }

        // Branch 3 — meta missing → title_meta names the meta tag specifically.
        do {
            let m = CompletenessMeasurement(
                title: "Has title",
                metaDescription: nil,
                internalLinks: [],
                images: []
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let tm = r.first { $0.assertionId == "completeness.title_meta" }!
            #expect(tm.passed == false)
            #expect(tm.advisory!.contains("meta"))
        }

        // Branch 4 — one 404 link → internal_links_resolve fails with count + preview.
        do {
            let m = CompletenessMeasurement(
                title: "Page",
                metaDescription: "Desc",
                internalLinks: [
                    Self.goodLink("https://example.com/ok"),
                    CompletenessMeasurement.InternalLink(href: "https://example.com/missing", statusCode: 404),
                ],
                images: [Self.goodImage("ok.png")]
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let links = r.first { $0.assertionId == "completeness.internal_links_resolve" }!
            #expect(links.passed == false)
            #expect(links.measured == 2)
            #expect(links.advisory!.contains("missing"))
            #expect(links.advisory!.contains("404"))
        }

        // Branch 5 — network-error link (statusCode nil) treated as fail.
        do {
            let m = CompletenessMeasurement(
                title: "Page",
                metaDescription: "Desc",
                internalLinks: [
                    CompletenessMeasurement.InternalLink(href: "https://example.com/unreachable", statusCode: nil),
                ],
                images: []
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let links = r.first { $0.assertionId == "completeness.internal_links_resolve" }!
            #expect(links.passed == false,
                    "network-error links must fail — not pass silently")
            #expect(links.advisory!.contains("no response"))
        }

        // Branch 6 — one img missing alt → img_alt fails with src preview.
        do {
            let m = CompletenessMeasurement(
                title: "Page",
                metaDescription: "Desc",
                internalLinks: [],
                images: [
                    Self.goodImage("ok.png"),
                    CompletenessMeasurement.ImageElement(src: "broken.png", alt: nil),
                    CompletenessMeasurement.ImageElement(src: "whitespace.png", alt: "   "),
                ]
            )
            let r = CompletenessAxis.evaluate(measurement: m)
            let alt = r.first { $0.assertionId == "completeness.img_alt" }!
            #expect(alt.passed == false)
            #expect(alt.measured == 3)
            #expect(alt.advisory!.contains("2"),
                    "two of three images (broken.png + whitespace.png) lack a usable alt; got: \(alt.advisory ?? "")")
            #expect(alt.advisory!.contains("broken.png"))
        }
    }
}
