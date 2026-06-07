import Testing
import Foundation
import JavaScriptCore

/// U.2b-1b-3 — pure-JS extraction parity tests.
///
/// The four axis bodies under `Resources/playwright-runner/axes/`
/// (`perf.js`, `security.js`, `design.js`, `completeness.js`) were
/// hoisted out of `runner.ts`'s `measure*` `page.evaluate(() => {...})`
/// closures so child U.2b-1b-4 (Swift `BrowserPaneRunner` lifecycle)
/// can `evaluateJavaScript(<bytes>)` against the SAME source string
/// the Playwright runner already feeds to Chromium. Child #6's parity
/// corpus diffs the two runners' outputs against the same bytes.
///
/// This test is the lightweight syntactic guard the U.2b-1b-3
/// `## Acceptance` checklist requires: each .js file must parse
/// without `SyntaxError` via JavaScriptCore's `new Function(<source>)`
/// path. Runtime execution is gated on a DOM, which neither node
/// `vm.runInNewContext()` nor JSCore can supply without a heavy
/// shim — child #6's parity corpus will diff actual measurement
/// outputs against pre-rendered fixtures.
@Suite("Playwright runner axis extraction — U.2b-1b-3")
struct PlaywrightRunnerAxisExtractionTests {

    /// Walk up from CWD looking for the Resources/playwright-runner/axes/
    /// directory. Mirrors the resolution shape used by
    /// PlaywrightRunnerPackageTests / PlaywrightRunnerSecurityMeasurementTests.
    private static func axesDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("Resources/playwright-runner/axes", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    @Test("each extracted axis JS body parses without SyntaxError")
    func eachAxisParses() throws {
        guard let dir = Self.axesDir() else {
            // Skip gracefully when run from outside a repo checkout.
            // PlaywrightRunnerPackageTests already validates the
            // package directory's presence and would surface that
            // gap first.
            return
        }

        let axes = ["perf", "security", "design", "completeness"]
        for axis in axes {
            let url = dir.appendingPathComponent("\(axis).js")
            let source = try String(contentsOf: url, encoding: .utf8)

            // Non-empty + reasonable size sanity check — catches a
            // truncated copy before the parse step blames the wrong
            // failure mode.
            #expect(source.count > 100,
                    "axes/\(axis).js source is implausibly short (\(source.count) bytes) — extraction may have been truncated")

            // IIFE shape — child #4's Swift loader will pass the raw
            // bytes to WKWebView.evaluateJavaScript, which expects
            // an expression, not a function body. The IIFE wrapper
            // is the byte-shape contract.
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(trimmed.hasSuffix("})()"),
                    "axes/\(axis).js must end with `})()`  — IIFE expression form is the contract with WKWebView.evaluateJavaScript")

            // Parse-only check via `new Function(<source>)`. JSCore
            // throws SyntaxError on malformed source; runtime errors
            // (e.g. `document is undefined`) do NOT fire because
            // `new Function` does not execute the body — it only
            // compiles it. This satisfies the U.2b-1b-3 acceptance's
            // OR clause (parse via `new Function`).
            let ctx = JSContext()!
            ctx.exception = nil

            // Embed the source as a JS string literal using JSON
            // encoding — JSONEncoder on a String produces a JSON
            // double-quoted, fully-escaped form that's a valid JS
            // string literal.
            let encoder = JSONEncoder()
            let sourceJSON = try encoder.encode(source)
            let sourceLiteral = String(data: sourceJSON, encoding: .utf8)!

            // `new Function(body)` — body must be statement-level.
            // The extracted IIFE expression is statement-valid when
            // used as a function body (it's a single expression
            // statement). If JSC parses it without exception, the
            // source is syntactically clean.
            _ = ctx.evaluateScript("new Function(\(sourceLiteral));")

            #expect(ctx.exception == nil,
                    "axes/\(axis).js failed `new Function` parse: \(ctx.exception?.toString() ?? "?")")
        }
    }

    @Test("runner.ts references all four extracted axis constants")
    func runnerLoadsExtractedAxes() throws {
        guard let dir = Self.axesDir() else { return }
        let runnerURL = dir.deletingLastPathComponent().appendingPathComponent("runner.ts")
        let source = try String(contentsOf: runnerURL, encoding: .utf8)

        // The four constants must be declared (loaded via
        // readFileSync at module init) AND consumed by the
        // measure* dispatch functions. Without these references,
        // child #4's WKWebView loader and the Playwright runner
        // would diverge silently.
        let constantSites: [String] = [
            "PERF_JS = readFileSync",
            "SECURITY_JS = readFileSync",
            "DESIGN_JS = readFileSync",
            "COMPLETENESS_JS = readFileSync",
        ]
        for site in constantSites {
            #expect(source.contains(site),
                    "runner.ts must declare `\(site)` so the extracted axis source is loaded at module init")
        }

        let dispatchSites: [String] = [
            "page.evaluate(PERF_JS)",
            "page.evaluate(SECURITY_JS)",
            "page.evaluate(DESIGN_JS)",
            "page.evaluate(COMPLETENESS_JS)",
        ]
        for site in dispatchSites {
            #expect(source.contains(site),
                    "runner.ts measure* function must dispatch via `\(site)` so the byte sequence sent to Chromium matches the extracted file content")
        }
    }
}
