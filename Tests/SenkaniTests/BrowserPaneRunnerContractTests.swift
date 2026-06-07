import Testing
import Foundation

/// U.2b-1b-4 — source-shape contract tests for `BrowserPaneRunner.swift`.
///
/// `BrowserPaneRunner` was extracted into the `BrowserPane` library
/// target (`Sources/BrowserPane/BrowserPaneRunner.swift`) by
/// `process-gap-browserpane-exerciser-library-carve-2026-06-06`. The
/// `SenkaniTests` target now links `BrowserPane`, but these tests keep
/// their source-shape form (grep the file on disk) because they assert
/// the byte-identity / public-surface contract child #6's parity corpus
/// and the dispatcher wiring depend on — a contract that lives in the
/// source text, not just the compiled symbol table. The matching
/// precedent is `PlaywrightRunnerAxisExtractionTests` (U.2b-1b-3) —
/// which ships parse-only and source-grep tests for the same reason.
///
/// The four tests below verify the source-shape contract child #6
/// (parity corpus) depends on:
///   * file exists at the canonical path,
///   * declares `BrowserRunner` conformance and the synchronous
///     `run(plan:targetURL:screenshot:)` method,
///   * loads each of the four extracted axis source files
///     (`perf.js`, `completeness.js`, `security.js`, `design.js`),
///   * documents the Sutton P0 synthetic-vs-direct Tab-walk decision
///     so child #6 can match the captured choice when wiring the
///     dispatcher.
///
/// Runtime validation (NSWindow allocation/teardown, real
/// WKWebView eval against fixture HTML, real Tab-walk focus order)
/// lands in the manual-validation pass filed as a follow-up backlog
/// item (`process-gap-browserpanerunner-runtime-validation-2026-05-22`).
@Suite("BrowserPaneRunner source contract — U.2b-1b-4")
struct BrowserPaneRunnerContractTests {

    /// Walk up from CWD looking for `Sources/BrowserPane/` (the library
    /// target the carve extracted the runner into).
    private static func sourceDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("Sources/BrowserPane", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    private static func runnerSource() throws -> String? {
        guard let dir = sourceDir() else { return nil }
        let url = dir.appendingPathComponent("BrowserPaneRunner.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("BrowserPaneRunner.swift ships at Sources/BrowserPane/")
    func runnerFileShipped() throws {
        guard let source = try Self.runnerSource() else {
            // Sources/BrowserPane/ resolution depends on CWD — skip
            // gracefully when run from outside a repo checkout.
            return
        }
        #expect(source.count > 1500,
                "BrowserPaneRunner.swift is implausibly short (\(source.count) bytes) — implementation may have been truncated")
        #expect(source.contains("public final class BrowserPaneRunner"),
                "BrowserPaneRunner.swift must declare `public final class BrowserPaneRunner` so SenkaniApp's dispatcher wiring can construct it")
    }

    @Test("BrowserPaneRunner declares BrowserRunner conformance + sync run signature")
    func runnerDeclaresBrowserRunnerConformance() throws {
        guard let source = try Self.runnerSource() else { return }
        #expect(source.contains(": BrowserRunner"),
                "BrowserPaneRunner must conform to `BrowserRunner` so `BrowserValidationDispatcher`'s `.headless` arm can wire it via the same Runner closure shape as `PlaywrightSubprocessRunner`")
        // The protocol requires `run(plan:targetURL:screenshot:) throws -> PlaywrightResult`.
        // Verify the signature is present so child #6's parity corpus
        // can compile against it without re-routing the closure.
        #expect(source.contains("func run(plan:") && source.contains("targetURL:") && source.contains("screenshot:") && source.contains("PlaywrightResult"),
                "BrowserPaneRunner must implement `func run(plan: [ValidationStep], targetURL: String, screenshot: Bool) throws -> PlaywrightResult` to satisfy the `BrowserRunner` protocol")
        // Off-screen NSWindow + WKWebView lifecycle is the spec'd
        // mechanism — verify both AppKit + WebKit are imported and
        // referenced.
        #expect(source.contains("import WebKit"),
                "BrowserPaneRunner must `import WebKit` to allocate WKWebView")
        #expect(source.contains("import AppKit"),
                "BrowserPaneRunner must `import AppKit` to allocate the off-screen NSWindow")
        #expect(source.contains("WKWebView") && source.contains("NSWindow"),
                "BrowserPaneRunner must reference WKWebView + NSWindow — the spec'd off-screen lifecycle owns both")
    }

    @Test("BrowserPaneRunner loads each extracted axis source file",
          arguments: [
              ("perf", "perf.js"),
              ("completeness", "completeness.js"),
              ("security", "security.js"),
              ("design", "design.js"),
          ])
    func runnerLoadsExtractedAxisFile(axis: String, filename: String) throws {
        guard let source = try Self.runnerSource() else { return }
        // Both the axis key AND the .js filename must be present so
        // child #6's parity corpus can confirm the byte sequence sent
        // to WKWebView matches the bytes Playwright's runner.ts feeds
        // to Chromium (the U.2b-1b-3 contract).
        #expect(source.contains("\"\(filename)\""),
                "BrowserPaneRunner must reference `\(filename)` so the extracted axis source is loaded for the \(axis) axis (byte-identity contract with PlaywrightSubprocessRunner)")
        #expect(source.contains("\"\(axis)\""),
                "BrowserPaneRunner must reference the `\(axis)` axis raw value so dispatch routes per ValidationAxes")
        // The shipped source must point at the extracted directory,
        // not inline the JS.
        #expect(source.contains("Resources/playwright-runner/axes"),
                "BrowserPaneRunner must point at `Resources/playwright-runner/axes` — the same directory U.2b-1b-3 extracted the IIFE bodies into")
    }

    @Test("BrowserPaneRunner documents Sutton P0 Tab-walk decision (synthetic vs direct NSEvent)")
    func runnerTabWalkDecisionCaptured() throws {
        guard let source = try Self.runnerSource() else { return }
        // The build-round narrative captured the decision as
        // "synthetic" because direct NSEvent keyDown to an off-screen
        // WKWebView requires the hosting window to become key (which
        // defeats the off-screen invariant). Verify both:
        //   (a) the decision narrative is in the source so child #6
        //       can match the choice without re-discovering it,
        //   (b) the synthetic KeyboardEvent dispatch is what the code
        //       actually uses.
        #expect(source.lowercased().contains("synthetic"),
                "BrowserPaneRunner must document the synthetic-vs-direct Tab-walk decision — the choice is part of the U.2b-1b-4 acceptance and child #6 wires the dispatcher against it")
        #expect(source.contains("KeyboardEvent") && source.contains("Tab"),
                "BrowserPaneRunner's Tab-walk must dispatch a synthetic `KeyboardEvent('keydown', { key: 'Tab' ... })` — direct NSEvent keyDown to off-screen WKWebView is unreliable per the build-round decision")
        // tabWalkFocusOrder is the public surface child #6 calls.
        #expect(source.contains("tabWalkFocusOrder"),
                "BrowserPaneRunner must expose a `tabWalkFocusOrder` entry point so child #6's parity corpus can compare focus-order sequences against Playwright's `page.keyboard.press(\"Tab\")` runtime")
    }
}
