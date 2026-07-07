import Testing
import Foundation
import BrowserPane

/// U.2b-2 GUI child a-2 — the wiring bridge that connects a
/// `dispatch: .pane` run's lock/banner outcome to the visible pane.
///
/// Two kinds of test live here, matching the item's honesty bar:
///   * **Pure-logic transition-table tests** — construct a fresh
///     `PaneDispatchStateStore` (NOT `.shared`, so tests stay isolated) and
///     drive its transitions headlessly. No display, no running app, no
///     WKWebView. These assert the store delegates to `PaneLockStateMachine`
///     and preserves its fail-closed edges, plus the "refusal payload is
///     present IFF the pane is refused" invariant.
///   * **Source-shape wiring tests** — grep the runner + view source to pin
///     the call-sites (the runner writes outcomes into the store keyed by the
///     resolved pane_id; the view observes the store) and the Schneier guard
///     (the store's refusal payload can carry no side-channel field).
///
/// What is NOT proven here (deferred to child 2's Cowork visual walk): that
/// the banner ACTUALLY renders on screen and the pane ACTUALLY visually
/// locks under a running app. These are source-shape + pure-logic only.
@Suite("PaneDispatchStateStore wiring bridge — U.2b-2 a-2")
struct PaneDispatchStateStoreTests {

    private let paneA = "pane-A"
    private let paneB = "pane-B"

    // MARK: - Transition table (pure logic, headless)

    @Test("fresh pane reads as unlocked — input enabled, no banner")
    func startsUnlocked() {
        let store = PaneDispatchStateStore()
        let s = store.state(for: paneA)
        #expect(s.lock.state == .unlocked)
        #expect(s.inputEnabled == true)
        #expect(s.bannerVisible == false)
        #expect(s.refusal == nil)
    }

    @Test("dispatch start locks the pane — input disabled, no banner")
    func dispatchStartLocks() {
        let store = PaneDispatchStateStore()
        let r = store.dispatchStarted(paneId: paneA)
        #expect(r == .success(.locked))
        let s = store.state(for: paneA)
        #expect(s.lock.state == .locked)
        #expect(s.inputEnabled == false)
        #expect(s.refusal == nil)
    }

    @Test("success unlocks — locked → unlocked, input re-enabled")
    func successUnlocks() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        let r = store.dispatchSucceeded(paneId: paneA)
        #expect(r == .success(.unlocked))
        let s = store.state(for: paneA)
        #expect(s.inputEnabled == true)
        #expect(s.refusal == nil)
    }

    @Test("refusal surfaces the banner and stays locked; payload carries axis + fixture")
    func refusalShowsBannerStaysLocked() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        let refusal = PaneDispatchStateStore.PaneRefusal(failingAxis: "security", fixtureId: "fix-42")
        let r = store.dispatchRefused(paneId: paneA, refusal: refusal)
        #expect(r == .success(.refused))
        let s = store.state(for: paneA)
        #expect(s.bannerVisible == true)
        #expect(s.inputEnabled == false)   // still locked while banner is up
        #expect(s.refusal == refusal)
        #expect(s.refusal?.failingAxis == "security")
        #expect(s.refusal?.fixtureId == "fix-42")
    }

    @Test("dismiss unlocks AND clears the refusal payload")
    func dismissUnlocksAndClears() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        store.dispatchRefused(paneId: paneA,
                              refusal: .init(failingAxis: "design", fixtureId: "fx"))
        let r = store.dismissBanner(paneId: paneA)
        #expect(r == .success(.unlocked))
        let s = store.state(for: paneA)
        #expect(s.inputEnabled == true)
        #expect(s.bannerVisible == false)
        #expect(s.refusal == nil)
    }

    @Test("fail-closed: double dispatch is rejected and does not mutate state")
    func doubleDispatchFailsClosed() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        let r = store.dispatchStarted(paneId: paneA)
        #expect(r == .failure(.doubleDispatch))
        // Unchanged — still exactly one dispatch in flight, no banner.
        let s = store.state(for: paneA)
        #expect(s.lock.state == .locked)
        #expect(s.refusal == nil)
    }

    @Test("fail-closed: dismiss while a dispatch is active is rejected, stays locked")
    func dismissWhileActiveFailsClosed() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        let r = store.dismissBanner(paneId: paneA)
        #expect(r == .failure(.dismissWhileActive))
        let s = store.state(for: paneA)
        #expect(s.lock.state == .locked)   // no banner to dismiss; lock intact
        #expect(s.refusal == nil)
    }

    @Test("retry: a new dispatch from the refused state relocks and CLEARS the banner")
    func retryFromRefusedRelocksAndClearsBanner() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        store.dispatchRefused(paneId: paneA,
                              refusal: .init(failingAxis: "perf", fixtureId: "fx"))
        let r = store.dispatchStarted(paneId: paneA)
        #expect(r == .success(.locked))
        let s = store.state(for: paneA)
        #expect(s.lock.state == .locked)
        // Invariant: refusal is non-nil IFF state == .refused — relock clears it.
        #expect(s.refusal == nil)
        #expect(s.bannerVisible == false)
    }

    @Test("per-pane keying is independent — locking one pane never touches another")
    func perPaneKeyingIsIndependent() {
        let store = PaneDispatchStateStore()
        store.dispatchStarted(paneId: paneA)
        store.dispatchRefused(paneId: paneA,
                              refusal: .init(failingAxis: "security", fixtureId: "fx"))
        // Pane B is untouched.
        let b = store.state(for: paneB)
        #expect(b.lock.state == .unlocked)
        #expect(b.inputEnabled == true)
        #expect(b.refusal == nil)
        // A is refused; the two keys do not bleed.
        let a = store.state(for: paneA)
        #expect(a.lock.state == .refused)
        #expect(a.refusal?.failingAxis == "security")
    }

    // MARK: - Schneier structural guard (store payload)

    @Test("SCHNEIER GUARD: PaneDispatchStateStore source never names a side-channel field")
    func storePayloadHasNoSideChannel() throws {
        guard let src = try Self.repoFile("Sources/BrowserPane/PaneDispatchStateStore.swift") else { return }
        // The refusal payload (`PaneRefusal`) must carry ONLY failingAxis +
        // fixtureId. The whole store file must never name the failed
        // assertion payload / captured runner output / plan step list.
        #expect(!src.contains("raw_output") && !src.contains("rawOutput"),
                "SCHNEIER VIOLATION: store references captured-output field — the refusal payload is failingAxis + fixtureId only")
        #expect(!src.contains("plan_steps") && !src.contains("planSteps"),
                "SCHNEIER VIOLATION: store references the validation plan step list — keep the refusal payload to two safe identifiers")
        // Positive assertion: the two safe fields ARE present.
        #expect(src.contains("failingAxis") && src.contains("fixtureId"),
                "PaneRefusal must declare exactly failingAxis + fixtureId")
    }

    // MARK: - Source-shape wiring call-sites (runner + view)

    @Test("runner writes its dispatch outcome into the store, keyed by the resolved pane_id")
    func runnerWiresStore() throws {
        guard let src = try Self.repoFile("Sources/BrowserPane/BrowserPaneRunner.swift") else { return }
        #expect(src.contains("PaneDispatchStateStore.shared"),
                "the visible-pane run must drive the process-global PaneDispatchStateStore.shared (outlives the per-dispatch runner)")
        #expect(src.contains("dispatchStarted(paneId:"),
                "the run must LOCK on dispatch start via the store, keyed by the resolved pane_id")
        #expect(src.contains("dispatchSucceeded(paneId:"),
                "the run must UNLOCK on success via the store")
        #expect(src.contains("dispatchRefused("),
                "the run must write a REFUSAL (banner) into the store on a failing axis")
        #expect(src.contains("PaneRefusal("),
                "the refusal payload must be a PaneRefusal (the Schneier-guarded two-field type)")
        // The old throwaway per-runner lock API must be GONE — its presence
        // would mean a second, per-dispatch source of truth (the very bug).
        #expect(!src.contains("private var lockState"),
                "the runner must no longer hold a throwaway per-instance lock — state lives in the pane-keyed store")
    }

    @Test("view observes the store and gates on the observed lock/banner state")
    func viewObservesStore() throws {
        guard let src = try Self.repoFile("SenkaniApp/Views/BrowserPaneView.swift") else { return }
        #expect(src.contains("@ObservedObject") && src.contains("PaneDispatchStateStore.shared"),
                "BrowserPaneView must @ObservedObject the shared PaneDispatchStateStore")
        #expect(src.contains("state(for: pane.id.uuidString)"),
                "the view must read the store entry keyed by its own pane.id")
        #expect(src.contains("paneState.inputEnabled"),
                "the URL bar + nav gestures must gate on the OBSERVED lock state")
        #expect(src.contains("paneState.refusal"),
                "the banner must render from the OBSERVED store payload")
        #expect(src.contains("dispatchStore.dismissBanner(paneId:"),
                "dismiss must route back through the store (delegates .bannerDismissed to the machine)")
        // The orphaned local mutation-island must be gone.
        #expect(!src.contains("@State private var paneLock"),
                "the orphaned local @State paneLock must be replaced by the observed store")
        #expect(!src.contains("@State private var refusalBanner"),
                "the orphaned local @State refusalBanner must be replaced by the observed store payload")
    }

    // MARK: - Helper

    /// Walk up from CWD to the repo root (dir containing `Package.swift`) and
    /// read `relativePath`. Returns nil when run outside a checkout — the
    /// source-shape tests then no-op (CI runs inside the checkout).
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
}
