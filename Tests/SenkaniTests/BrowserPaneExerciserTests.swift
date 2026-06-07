import Testing
import Foundation
import BrowserPane
import Core

/// process-gap-browserpane-exerciser-library-carve-2026-06-06 —
/// structural tests for the BrowserPane library extraction + the
/// direct-API exerciser CLI scaffold.
///
/// Scope fence (Carmack): these tests do NOT spawn a WKWebView or an
/// NSWindow. The GUI-runtime exerciser modes (`deadlock` watchdog demo,
/// `window-count` NSWindow leak probe) and the live `tab-walk` run
/// against a real page stay with the parent's Cowork walk
/// (`process-gap-browserpane-direct-api-exerciser-2026-05-22`). What
/// this child verifies:
///   1. the `BrowserPane` library target links + the moved runner's
///      public `BrowserRunner` conformance is intact (now exercised via
///      the compiled symbol, since the runner is a linkable module);
///   2. the exerciser's `tab-walk` handler dispatches to the public
///      `BrowserPaneRunner.tabWalkFocusOrder` API (source-shape — no
///      live run);
///   3. the deferred modes (`deadlock` / `window-count`) print the
///      `deferred-to-cowork-walk` sentinel and exit 0 (binary
///      invocation — the scope fence is observable behavior, not a
///      comment).
@Suite("BrowserPane exerciser carve — library extraction + CLI scaffold")
struct BrowserPaneExerciserTests {

    // MARK: - Test 1: BrowserPane library links; BrowserRunner conformance intact

    @Test("BrowserPane library links and BrowserPaneRunner conforms to BrowserRunner (compiled-symbol contract)")
    func libraryLinksAndConforms() throws {
        // The runner is now a linkable module symbol — construct one and
        // bind it to the `BrowserRunner` existential. If the extraction
        // dropped the conformance or the public init, this fails to
        // compile (the strongest possible structural assertion).
        let runner = BrowserPaneRunner()
        let asProtocol: any BrowserRunner = runner
        #expect(type(of: asProtocol) == BrowserPaneRunner.self,
                "BrowserPaneRunner must conform to BrowserRunner so the dispatcher's .headless arm can wire it")

        // The egress-wiring public surface child #6's dispatcher calls
        // must remain accessible from the library boundary.
        #expect(BrowserPaneRunner.makeProxyConfiguration(proxyURL: nil) == nil,
                "makeProxyConfiguration(nil) must be a no-proxy no-op (default-OFF / source-compatible default)")
        #expect(BrowserPaneRunner.writeEgressOverridePolicy(targetURL: "https://example.com", proxyURL: nil) == nil,
                "writeEgressOverridePolicy with nil proxy must be a no-op (no temp file written when no proxy is configured)")

        // The axis-filename contract (byte-identity with the Playwright
        // runner) survives the move.
        #expect(BrowserPaneRunner.axisJSFilenames["perf"] == "perf.js")
        #expect(BrowserPaneRunner.axisJSFilenames.count == 4)
    }

    // MARK: - Test 2: covered by the existing BrowserPaneRunner* suites
    //
    // BrowserPaneRunnerContractTests, BrowserPaneRunnerEgressWiringTests,
    // and BrowserPaneRunnerParityTests continue to compile + pass after
    // the move (their source-grep helpers were re-pointed at
    // Sources/BrowserPane/). The no-regression invariant (plan test #2)
    // is enforced by those suites running green in the same `swift test`.

    // MARK: - Test 3: tab-walk handler dispatches to the public API

    @Test("exerciser --mode tab-walk wires to BrowserPaneRunner.tabWalkFocusOrder (source-shape, no live run)")
    func tabWalkWiresToPublicAPI() throws {
        guard let source = try Self.exerciserSource() else {
            // tools/browserpane-exerciser/ resolution depends on CWD —
            // skip gracefully when run from outside a checkout.
            return
        }
        #expect(source.contains("import BrowserPane"),
                "exerciser must `import BrowserPane` — the library boundary this carve created")
        #expect(source.contains("tabWalkFocusOrder"),
                "exerciser's --mode tab-walk must dispatch to the public BrowserPaneRunner.tabWalkFocusOrder API")
        #expect(source.contains("BrowserPaneRunner("),
                "exerciser must construct a BrowserPaneRunner instance to drive the tab walk")
        // The three modes are declared up front so the exerciser surface
        // is documented even though two are deferred.
        #expect(source.contains("\"tab-walk\"") && source.contains("\"window-count\""),
                "exerciser must declare all three modes (tab-walk implemented, deadlock + window-count deferred)")
        // Scope fence: the deferred modes must emit the sentinel, NOT
        // spawn a WKWebView / NSWindow from the exerciser's own corpus.
        #expect(source.contains("deferred-to-cowork-walk"),
                "exerciser's deadlock + window-count modes must print the deferred-to-cowork-walk sentinel")
        // Import-level scope fence: the exerciser must NOT import WebKit
        // or AppKit directly — the GUI surface lives behind the
        // BrowserPane library boundary. (A source-text grep for
        // `WKWebView`/`NSWindow` would false-positive on the doc-comment
        // narrative describing what BrowserPaneRunner allocates, so the
        // fence is asserted at the import line — the load-bearing seam.)
        #expect(!source.contains("import WebKit"),
                "exerciser must NOT `import WebKit` — WKWebView allocation lives behind the BrowserPane library boundary (scope fence)")
        #expect(!source.contains("import AppKit"),
                "exerciser must NOT `import AppKit` — NSWindow allocation lives behind the BrowserPane library boundary (scope fence)")
    }

    // MARK: - Test 4: deferred modes print the sentinel + exit 0 (binary run)

    @Test("exerciser --mode deadlock / --mode window-count print the deferred sentinel and exit 0",
          arguments: ["deadlock", "window-count"])
    func deferredModesPrintSentinelExitZero(mode: String) throws {
        guard let binary = Self.exerciserBinaryURL() else {
            // No built product (e.g. running tests without a prior build
            // of the exerciser target) — skip gracefully.
            return
        }
        let proc = Process()
        proc.executableURL = binary
        proc.arguments = ["--mode", mode]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        try proc.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        #expect(proc.terminationStatus == 0,
                "--mode \(mode) must exit 0 (the deferred sentinel is a clean exit, not a failure)")
        let out = String(data: data, encoding: .utf8) ?? ""
        #expect(out.contains("\"status\":\"deferred-to-cowork-walk\""),
                "--mode \(mode) must print the deferred-to-cowork-walk sentinel; got: \(out)")
        #expect(out.contains("\"mode\":\"\(mode)\""),
                "--mode \(mode) sentinel must echo the requested mode; got: \(out)")
    }

    // MARK: - Helpers

    private static func repoRoot() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return cur
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    private static func exerciserSource() throws -> String? {
        guard let root = repoRoot() else { return nil }
        let url = root.appendingPathComponent("tools/browserpane-exerciser/main.swift")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Resolve the built `browserpane-exerciser` binary next to the test
    /// bundle (SwiftPM places all products in the same build dir).
    private static func exerciserBinaryURL() -> URL? {
        let buildDir = Bundle.main.bundleURL.deletingLastPathComponent()
        let candidate = buildDir.appendingPathComponent("browserpane-exerciser")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        // Fallback: the test bundle's own directory.
        let alt = Bundle.main.bundleURL.appendingPathComponent("browserpane-exerciser")
        if FileManager.default.isExecutableFile(atPath: alt.path) {
            return alt
        }
        return nil
    }
}
