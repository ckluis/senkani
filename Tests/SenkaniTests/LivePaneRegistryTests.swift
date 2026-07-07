import Testing
import Foundation
import BrowserPane
import Core

/// U.2b-2 GUI child a-1 — fail-closed `pane_id` → live-pane resolution.
/// A plain `Dummy` object stands in for a live `WKWebView` so these run
/// headlessly (no display / WebKit process). The security invariant under
/// test: an unknown or closed `pane_id` REFUSES — it never resolves to a
/// different live pane.
@Suite("LivePaneRegistry fail-closed resolution — U.2b-2 a-1")
struct LivePaneRegistryTests {

    private final class Dummy {}

    @Test("registered pane resolves to itself; surface is non-nil")
    func resolvedPane() {
        let reg = LivePaneRegistry()
        let surface = Dummy()
        reg.register(paneId: "A", surface: surface)
        #expect(reg.resolve(paneId: "A") == .resolved(paneId: "A"))
        #expect(reg.surface(paneId: "A") != nil)
    }

    @Test("fail-closed: unknown pane_id refuses (.unknownPane), surface nil")
    func unknownPaneRefuses() {
        let reg = LivePaneRegistry()
        reg.register(paneId: "A", surface: Dummy())
        #expect(reg.resolve(paneId: "B") == .unknownPane(requested: "B"))
        #expect(reg.surface(paneId: "B") == nil)
    }

    @Test("fail-closed: NEVER resolves a requested id to a DIFFERENT live pane")
    func neverDifferentPane() {
        let reg = LivePaneRegistry()
        let a = Dummy()
        reg.register(paneId: "A", surface: a)
        // "B" is unknown — resolution must refuse, and surface(B) must NOT
        // return A's surface even though A is the only live pane.
        #expect(reg.surface(paneId: "B") == nil)
        // Sanity: A's own surface is still its own object.
        #expect(reg.surface(paneId: "A") === a)
    }

    @Test("fail-closed: a closed (deallocated) pane refuses (.closedPane)")
    func closedPaneRefuses() {
        let reg = LivePaneRegistry()
        var obj: Dummy? = Dummy()
        reg.register(paneId: "C", surface: obj!)
        #expect(reg.resolve(paneId: "C") == .resolved(paneId: "C"))
        obj = nil  // pane closed — weak ref nils out
        #expect(reg.resolve(paneId: "C") == .closedPane(requested: "C"))
        #expect(reg.surface(paneId: "C") == nil)
    }

    @Test("unregister makes the id stale — subsequent resolve refuses")
    func unregisterMakesStale() {
        let reg = LivePaneRegistry()
        reg.register(paneId: "A", surface: Dummy())
        reg.unregister(paneId: "A")
        #expect(reg.resolve(paneId: "A") == .unknownPane(requested: "A"))
    }

    @Test("nil pane_id resolves to most-recently-focused live pane; .noPanes when empty")
    func nilResolvesMostRecent() {
        let reg = LivePaneRegistry()
        #expect(reg.resolve(paneId: nil) == .noPanes)
        let a = Dummy(); let b = Dummy()
        reg.register(paneId: "A", surface: a)
        reg.register(paneId: "B", surface: b)
        #expect(reg.resolve(paneId: nil) == .resolved(paneId: "B"))  // most recent
        reg.markFocused(paneId: "A")
        #expect(reg.resolve(paneId: nil) == .resolved(paneId: "A"))
        reg.unregister(paneId: "A")
        #expect(reg.resolve(paneId: nil) == .resolved(paneId: "B"))  // falls to next live
    }

    /// Adversarial bar — registering the VISIBLE-pane factory must NOT
    /// disturb the HEADLESS slot: `dispatch: .headless` keeps its runner.
    @Test("headless + pane registry slots are independent — pane registration does not clear headless")
    func dispatchRegistrySlotsIndependent() {
        final class StubRunner: BrowserRunner, @unchecked Sendable {
            func run(plan: [ValidationStep], targetURL: String, screenshot: Bool) throws -> PlaywrightResult {
                PlaywrightResult(resultStatus: "pass", axesRun: [], assertionsPassed: 0, assertionsFailed: 0, screenshotPath: nil, advisory: nil)
            }
        }
        // Clean baseline.
        BrowserDispatchRegistry.registerHeadlessRunnerFactory(nil)
        BrowserDispatchRegistry.registerPaneRunnerFactory(nil)

        BrowserDispatchRegistry.registerHeadlessRunnerFactory { _ in StubRunner() }
        #expect(BrowserDispatchRegistry.headlessRunnerFactory() != nil)

        // Register the pane slot — headless must be untouched.
        BrowserDispatchRegistry.registerPaneRunnerFactory { _ in StubRunner() }
        #expect(BrowserDispatchRegistry.headlessRunnerFactory() != nil,
                "registering the pane factory must NOT clear the headless slot")
        #expect(BrowserDispatchRegistry.paneRunnerFactory() != nil)

        // Both closures resolve to a runner independently.
        #expect(BrowserDispatchRegistry.makeHeadlessRunnerClosure(egressProxyURL: nil) != nil)
        #expect(BrowserDispatchRegistry.makePaneRunnerClosure(egressProxyURL: nil) != nil)

        // Teardown — leave both slots clear for other tests.
        BrowserDispatchRegistry.registerHeadlessRunnerFactory(nil)
        BrowserDispatchRegistry.registerPaneRunnerFactory(nil)
    }
}
