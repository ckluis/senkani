import Testing
import Foundation

/// Structural (source-shape) contract for
/// `browserpane-runner-evaluatejs-no-promise-await-2026-07-05`.
///
/// **Why source-shape.** The bug is a WebKit-API-choice invariant that
/// lives in the source text: the off-screen runner MUST await a
/// Promise-returning axis (`perf.js`) before WKWebView marshals the
/// result. The legacy `evaluateJavaScript(_:completionHandler:)` hands a
/// returned `Promise` back un-awaited, so WKWebView cannot marshal it
/// (`WKErrorDomain Code=5`, "unsupported type") and the perf axis fails
/// on EVERY page. The fix routes the axis-eval path through
/// `callAsyncJavaScript` (macOS 11+), which runs the source as an async
/// function body and awaits the returned value. The runtime proof
/// (`validate_browser dispatch=headless` returns `result_status: pass`)
/// is a same-machine WKWebView walk filed as deferred evidence on the
/// item; this test is the durable regression guard that a future edit
/// cannot silently revert the runner to the un-awaiting API.
///
/// The single load-bearing guard: `webView.callAsyncJavaScript(` is the
/// eval call, and `webView.evaluateJavaScript(` (the legacy call form)
/// is ABSENT. A revert to `webView.evaluateJavaScript(js) { … }` fails
/// this test.
@Suite("BrowserPaneRunner Promise-awaiting eval — callAsyncJavaScript contract")
struct BrowserPaneRunnerAsyncEvalTests {

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
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Runner awaits Promise-returning axes via callAsyncJavaScript, never the legacy evaluateJavaScript call")
    func runnerUsesCallAsyncJavaScript() throws {
        guard let source = try Self.runnerSource() else {
            // Sources/BrowserPane resolution depends on CWD — skip
            // gracefully when run from outside a checkout.
            return
        }

        // 1) The eval path calls callAsyncJavaScript on the web view.
        #expect(source.contains("webView.callAsyncJavaScript("),
                "BrowserPaneRunner must evaluate axis JS via `webView.callAsyncJavaScript(...)` (macOS 11+) so a Promise-returning axis (perf.js) is awaited before WKWebView marshals it — the legacy `evaluateJavaScript` hands the Promise back un-awaited (WKErrorDomain Code=5).")

        // 2) The legacy CALL form must be absent. This is the revert
        //    guard: `webView.evaluateJavaScript(js) { … }` reintroduces
        //    the Code=5 perf failure. (Prose in doc comments may still
        //    NAME `evaluateJavaScript(_:completionHandler:)` to explain
        //    what was replaced — the guard is on the receiver-call form
        //    `webView.evaluateJavaScript(`, not the bare identifier.)
        #expect(!source.contains("webView.evaluateJavaScript("),
                "BrowserPaneRunner must NOT call `webView.evaluateJavaScript(...)` — that legacy API cannot await a returned Promise, so perf.js fails on every page with WKErrorDomain Code=5. Use `callAsyncJavaScript` instead.")

        // 3) The IIFE-expression axis source is wrapped as an async
        //    function BODY. callAsyncJavaScript runs statements, not an
        //    expression, so the axis IIFE (an expression) must be
        //    `return (...)`-wrapped for the awaited value to flow back.
        #expect(source.contains("return (") ,
                "BrowserPaneRunner must wrap the axis IIFE expression in a `return (...)` async-function body — callAsyncJavaScript executes statements, and only a returned (awaited) value marshals back. This is what keeps the axis .js files usable by BOTH Playwright's page.evaluate AND WKWebView (branch-per-runner wrapping).")

        // 4) The eval runs in the page's own JS world. callAsyncJavaScript
        //    has NO default content world (unlike evaluateJavaScript), so a
        //    world MUST be named; `.page` keeps axis DOM/PerformanceObserver
        //    reads in the page's world, matching prior evaluateJavaScript
        //    behavior. (The SDK labels the content-world param `in:`.)
        #expect(source.contains("in: .page"),
                "BrowserPaneRunner's callAsyncJavaScript call must run in `in: .page` (WKContentWorld.page) — the page's own JS world, matching the prior evaluateJavaScript behavior so axis DOM/PerformanceObserver reads resolve identically.")
    }
}
