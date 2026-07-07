import Testing
import Foundation

/// U.2b-2 GUI child a-1 — source-shape / structural contract tests, in the
/// `BrowserPaneRunnerContractTests` / `BrowserPaneRunnerEgressWiringTests`
/// style (grep the file on disk). These assert the wiring contract lives in
/// the source text: the boot-time pane-factory registration, the
/// visible-pane runner binding, and the refusal-banner Schneier guard.
///
/// Honesty bar (carried from the item acceptance): NOTHING here verifies
/// real banner rendering, real lock UX under a running app, or real
/// WKWebView runtime parity — those are sibling
/// `phase-u2b-2-pane-gui-banner-lock-a-2`'s real-runtime fixtures + Cowork
/// visual walk. These tests are source-shape + pure-logic only.
@Suite("BrowserPane banner+lock source contract — U.2b-2 a-1")
struct BrowserPaneBannerLockContractTests {

    /// Walk up from CWD to the repo root (the dir containing `Package.swift`)
    /// and read `relativePath`. Returns nil when run outside a checkout.
    private static func repoFile(_ relativePath: String) throws -> String? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let pkg = cur.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                let target = cur.appendingPathComponent(relativePath)
                guard FileManager.default.fileExists(atPath: target.path) else { return nil }
                return try String(contentsOf: target, encoding: .utf8)
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    // MARK: - Factory registration wiring

    @Test("main.swift registers the visible-pane runner factory at boot")
    func mainRegistersPaneFactory() throws {
        guard let src = try Self.repoFile("SenkaniApp/App/main.swift") else { return }
        #expect(src.contains("BrowserPaneRunnerFactory.registerPaneRunner()"),
                "main.swift must call BrowserPaneRunnerFactory.registerPaneRunner() at boot so `dispatch: .pane` stops fail-closed-refusing when the app runs (mirrors the existing register() headless call)")
        // The headless registration must still be present — the pane
        // registration is ADDITIVE, not a replacement.
        #expect(src.contains("BrowserPaneRunnerFactory.register()"),
                "main.swift must keep the headless BrowserPaneRunnerFactory.register() call — pane registration is additive")
    }

    @Test("BrowserPaneRunnerFactory wires registerPaneRunnerFactory mirroring the headless slot")
    func factoryWiresPaneSlot() throws {
        guard let src = try Self.repoFile("Sources/BrowserPane/BrowserPaneRunnerFactory.swift") else { return }
        #expect(src.contains("BrowserDispatchRegistry.registerPaneRunnerFactory"),
                "BrowserPaneRunnerFactory.registerPaneRunner() must call BrowserDispatchRegistry.registerPaneRunnerFactory (mirroring registerHeadlessRunnerFactory)")
        #expect(src.contains(".visiblePane"),
                "the pane factory must construct a `.visiblePane` BrowserPaneRunner, not the off-screen default")
        // Both slots wired from the same factory type — headless untouched.
        #expect(src.contains("registerHeadlessRunnerFactory"),
                "the headless registration must remain — the pane slot is independent")
    }

    // MARK: - Visible-pane runner binding

    @Test("BrowserPaneRunner ships a visible-pane mode bound to the live-pane registry, fail-closed")
    func runnerVisiblePaneMode() throws {
        guard let src = try Self.repoFile("Sources/BrowserPane/BrowserPaneRunner.swift") else { return }
        #expect(src.contains("case visiblePane") || src.contains("visiblePane(paneId:"),
                "BrowserPaneRunner.Mode must have a `.visiblePane(paneId:)` case binding to the live pane")
        #expect(src.contains("LivePaneRegistry"),
                "the visible-pane run must resolve the pane via LivePaneRegistry")
        #expect(src.contains("validation_browser_pane_unresolved"),
                "an unresolved pane_id must fail CLOSED with a structured refusal advisory, never a fabricated pass or a fall-back to a different pane")
        // U.2b-2 a-2 rewire: the pane lock/banner outcome is written into
        // the process-global `PaneDispatchStateStore` (keyed by the resolved
        // pane_id) instead of a throwaway per-runner `PaneLockStateMachine`.
        // The store — not the runner — holds the persistent per-pane machine,
        // so the double-dispatch guard checks stable state across dispatches.
        #expect(src.contains("PaneDispatchStateStore"),
                "the visible-pane run must drive the process-global PaneDispatchStateStore (keyed by pane_id), which outlives the per-dispatch runner and delegates transitions to PaneLockStateMachine")
        #expect(src.contains("validation_browser_pane_busy"),
                "a double dispatch on the same pane must fail closed (busy refusal), not run twice concurrently")
    }

    // MARK: - Refusal banner + Schneier guard

    @Test("RefusalBannerView shows failing_axis + fixture_id, ✕ dismiss, Open advisory → stdout")
    func bannerSurfaceShape() throws {
        guard let src = try Self.repoFile("SenkaniApp/Views/RefusalBannerView.swift") else { return }
        #expect(src.contains("failingAxis"),
                "banner must surface the failing axis")
        #expect(src.contains("fixtureId"),
                "banner must surface the fixture id")
        #expect(src.contains("xmark"),
                "banner must have a single ✕ dismiss control (SF Symbol `xmark`)")
        #expect(src.contains("Open advisory"),
                "banner must have an `Open advisory` affordance")
        #expect(src.contains("FileHandle.standardOutput"),
                "`Open advisory` must print the advisory to dispatch stdout")
    }

    @Test("SCHNEIER GUARD: banner source never references the forbidden side-channel fields")
    func bannerSchneierGuard() throws {
        guard let src = try Self.repoFile("SenkaniApp/Views/RefusalBannerView.swift") else { return }
        // The banner shows ONLY failing_axis + fixture_id. It must NEVER
        // reference the failed assertion payload / captured runner output /
        // validation plan step list — the side-channel fields.
        #expect(!src.contains("raw_output"),
                "SCHNEIER VIOLATION: banner source references `raw_output` — the refusal banner must never surface captured runner output")
        #expect(!src.contains("plan_steps"),
                "SCHNEIER VIOLATION: banner source references `plan_steps` — the refusal banner must never surface the validation plan step list")
        #expect(!src.contains("rawOutput") && !src.contains("planSteps"),
                "SCHNEIER VIOLATION: banner source references a camelCase side-channel field — keep the model to failingAxis + fixtureId only")
    }

    // MARK: - BrowserPaneView integration

    @Test("BrowserPaneView integrates the banner overlay + input-lock + registry lifecycle")
    func paneViewIntegration() throws {
        guard let src = try Self.repoFile("SenkaniApp/Views/BrowserPaneView.swift") else { return }
        #expect(src.contains("RefusalBannerView"),
                "BrowserPaneView must render the RefusalBannerView overlay at the top of the pane")
        // U.2b-2 a-2 rewire: the view OBSERVES `PaneDispatchStateStore` and
        // gates on `paneState.inputEnabled` (the observed store entry for
        // this pane), replacing the orphaned local `@State paneLock`.
        #expect(src.contains("PaneDispatchStateStore"),
                "BrowserPaneView must observe PaneDispatchStateStore (replacing the orphaned local @State paneLock / @State refusalBanner mutation-island)")
        #expect(src.contains("paneState.inputEnabled"),
                "BrowserPaneView must gate the URL bar + nav gestures on the OBSERVED lock state (.disabled(!paneState.inputEnabled))")
        #expect(src.contains("paneState.refusal"),
                "BrowserPaneView must render the banner from the OBSERVED store payload (paneState.refusal), not a local @State island")
        #expect(src.contains("LivePaneRegistry.shared.register") && src.contains("LivePaneRegistry.shared.unregister"),
                "BrowserPaneView must publish/withdraw its live WKWebView to/from LivePaneRegistry on appear/disappear so pane_id resolution is fail-closed on a closed pane")
    }
}
