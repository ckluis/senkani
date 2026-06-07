import Foundation
import Testing
import WebKit
@testable import Core

/// V.10b tests — parser + stylesheet + user-script factory +
/// drift detection against the on-disk canonical spec.
@Suite("DesignSystemPatterns")
struct DesignSystemPatternsTests {

    // MARK: - Parser

    @Test("Parser happy path: canonical resource parses into a four-slot rule set")
    func parserHappyPath() throws {
        let ruleSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        for slot in DesignSystemSlot.allCases {
            #expect(!ruleSet.rules(for: slot).isEmpty,
                    "slot \(slot.rawValue) must be non-empty")
        }
        #expect(ruleSet.totalRuleCount >= 12,
                "canonical resource must define at least 12 rules; got \(ruleSet.totalRuleCount)")
    }

    @Test("Parser malformed: missing section raises typed error")
    func parserMissingSection() throws {
        let md = """
        # Title

        ## Spacing
        - spacing.unit: 4px

        ## Contrast
        - contrast.body-min: 4.5

        ## Hierarchy
        - hierarchy.h1-scale: 2.4
        """
        do {
            _ = try DesignSystemPatternParser.parse(md)
            Issue.record("expected missingSection error for Type scale")
        } catch let DesignSystemPatternParseError.missingSection(slot) {
            #expect(slot == .typeScale)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("Parser malformed: line without ':' raises typed error")
    func parserMalformedLine() throws {
        let md = """
        ## Spacing
        - spacing.unit 4px

        ## Contrast
        - contrast.body-min: 4.5

        ## Hierarchy
        - hierarchy.h1-scale: 2.4

        ## Type scale
        - typeScale.base: 1rem
        """
        do {
            _ = try DesignSystemPatternParser.parse(md)
            Issue.record("expected malformedLine error")
        } catch let DesignSystemPatternParseError.malformedLine(lineNumber, _, reason) {
            #expect(lineNumber > 0)
            #expect(reason.contains(":"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - Stylesheet

    @Test("Stylesheet determinism: same input twice yields byte-identical output")
    func stylesheetDeterminism() throws {
        let ruleSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        let a = DesignSystemStylesheet.css(from: ruleSet)
        let b = DesignSystemStylesheet.css(from: ruleSet)
        #expect(a == b)
        #expect(!a.isEmpty)
    }

    @Test("Stylesheet content sanity: includes :root, body, and h1 selectors")
    func stylesheetSelectorCoverage() throws {
        let ruleSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        let css = DesignSystemStylesheet.css(from: ruleSet)
        #expect(css.contains(":root {"),
                "stylesheet must define :root tokens")
        #expect(css.contains("body {"),
                "stylesheet must define a body rule")
        #expect(css.contains("h1 {"),
                "stylesheet must define an h1 rule")
        // The three minimum surfaces guarantee the toggle feels visibly different.
    }

    // MARK: - User-script factory

    @Test("UserScript factory: .original returns zero scripts")
    @MainActor
    func userScriptsOriginalEmpty() {
        let scripts = DesignSystemUserScript.userScripts(
            for: .original,
            css: "body { color: red; }"
        )
        #expect(scripts.isEmpty)
    }

    @Test("UserScript factory: .designSystem returns one script wrapping <style>")
    @MainActor
    func userScriptsDesignSystemWrapsStyle() {
        let css = "body { color: rebeccapurple; }"
        let scripts = DesignSystemUserScript.userScripts(for: .designSystem, css: css)
        #expect(scripts.count == 1)

        let source = DesignSystemUserScript.makeSource(css: css)
        // Source must literally inject a `<style data-senkani-design-system="1">`
        // block — the marker attribute is the test-canonical signal.
        #expect(source.contains("<style data-senkani-design-system=\"1\">"))
        #expect(source.contains("</style>"))
        #expect(source.contains("rebeccapurple"))

        if let only = scripts.first {
            #expect(only.injectionTime == .atDocumentEnd)
            #expect(only.isForMainFrameOnly == false)
        }
    }

    @Test("UserScript count matches WKUserContentController across mode flips")
    @MainActor
    func userContentControllerCountAcrossFlips() throws {
        let ruleSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        let css = DesignSystemStylesheet.css(from: ruleSet)
        let controller = WKUserContentController()

        // Start in .original — zero scripts.
        for s in DesignSystemUserScript.userScripts(for: .original, css: css) {
            controller.addUserScript(s)
        }
        #expect(controller.userScripts.count == 0)

        // Flip to .designSystem — one script.
        controller.removeAllUserScripts()
        for s in DesignSystemUserScript.userScripts(for: .designSystem, css: css) {
            controller.addUserScript(s)
        }
        #expect(controller.userScripts.count == 1)

        // Flip back to .original — zero scripts.
        controller.removeAllUserScripts()
        for s in DesignSystemUserScript.userScripts(for: .original, css: css) {
            controller.addUserScript(s)
        }
        #expect(controller.userScripts.count == 0)
    }

    // MARK: - On-disk spec drift detection

    @Test("On-disk spec/design_system_patterns.md matches embedded canonical")
    func onDiskSpecMatchesEmbedded() throws {
        // The test must run from the repo root (CWD has `spec/`). When run
        // from a different CWD, the file lookup falls back to skipping.
        let path = "spec/design_system_patterns.md"
        guard let onDisk = try? String(contentsOfFile: path, encoding: .utf8) else {
            // Skip — running outside the repo. We don't fail the suite here.
            return
        }
        // Parse both — drift in *parsed shape* is what matters; trailing
        // newlines or whitespace differences between the source file and
        // the heredoc are not user-visible.
        let onDiskSet = try DesignSystemPatternParser.parse(onDisk)
        let embeddedSet = try DesignSystemPatternParser.parse(
            DesignSystemPatternsResource.canonicalMarkdown
        )
        #expect(onDiskSet == embeddedSet,
                "spec/design_system_patterns.md drifted from DesignSystemPatternsResource.canonicalMarkdown — keep them in sync")
    }
}
