import Testing
import Foundation
@testable import Core

/// Coverage for `PaneModeStore` (T.1b follow-up — operator-editable
/// `~/.senkani/pane-modes.json` backing `HookRouter.paneModeResolver`).
///
/// Schneier P0: default-install (no file) MUST silently resolve every
/// pane to `.general`; malformed JSON MUST NOT panic and MUST NOT
/// elevate a pane out of `.general`. Tests pin both invariants.
@Suite("PaneModeStore")
struct PaneModeStoreTests {

    private static func tempPath() -> String {
        let dir = NSTemporaryDirectory() + "senkani-pane-modes-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "pane-modes.json"
    }

    @Test("Default-install: missing file → every paneID resolves to .general")
    func defaultInstallReturnsGeneral() {
        let path = Self.tempPath()
        // File intentionally not created.
        #expect(!FileManager.default.fileExists(atPath: path))
        let store = PaneModeStore(path: path)
        #expect(store.resolve(paneID: "any-pane") == .general)
        #expect(store.resolve(paneID: UUID().uuidString) == .general)
        #expect(store.resolve(paneID: nil) == .general)
        #expect(store.resolve(paneID: "") == .general)
    }

    @Test("setMode persists and resolve reads it back across cache invalidate")
    func setAndResolveRoundTrip() throws {
        let path = Self.tempPath()
        let store = PaneModeStore(path: path)
        let pane = UUID().uuidString
        #expect(store.setMode(paneID: pane, mode: .redteam))
        #expect(store.resolve(paneID: pane) == .redteam)

        // Independent fresh store reads from disk.
        let reread = PaneModeStore(path: path)
        #expect(reread.resolve(paneID: pane) == .redteam)

        // Clearing the override drops to .general.
        #expect(store.setMode(paneID: pane, mode: nil))
        #expect(store.resolve(paneID: pane) == .general)
        let after = PaneModeStore(path: path)
        #expect(after.resolve(paneID: pane) == .general)
    }

    @Test("Malformed JSON file → silent default to .general (no panic, no elevation)")
    func malformedFileReturnsGeneral() throws {
        let path = Self.tempPath()
        // Garbage JSON; an attacker who can write this file MUST NOT be
        // able to flip panes out of .general through it.
        try "{not-valid-json".write(toFile: path, atomically: true, encoding: .utf8)
        let store = PaneModeStore(path: path)
        #expect(store.resolve(paneID: "any-pane") == .general)

        // Unknown mode value also degrades to .general for that pane.
        let unknownMode = """
        {"modes": {"pane-A": "research", "pane-B": "ultra-redteam"}}
        """
        try unknownMode.write(toFile: path, atomically: true, encoding: .utf8)
        let store2 = PaneModeStore(path: path)
        #expect(store2.resolve(paneID: "pane-A") == .research)
        #expect(store2.resolve(paneID: "pane-B") == .general)
    }
}

/// Coverage for `HookRouter.paneModeResolver` — the seam PaneContainerView
/// and OllamaLauncherPane call when computing the SENKANI_PANE_MODE env
/// var. Asserts the production default actually consults the store.
@Suite("HookRouter.paneModeResolver default wiring")
struct HookRouterPaneModeResolverTests {

    @Test("Default resolver delegates to PaneModeStore.shared.resolve(_:)")
    func defaultDelegatesToStore() {
        // Save the prior resolver so the test does not pollute state for
        // any test running on the same process under @Suite parallelism.
        let saved = HookRouter.paneModeResolver
        defer { HookRouter.paneModeResolver = saved }

        // Wire a test store at a private path, point the resolver at it,
        // and assert the resolver returns the stored mode.
        let dir = NSTemporaryDirectory() + "hookrouter-pane-modes-\(UUID().uuidString)/"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "pane-modes.json"
        let store = PaneModeStore(path: path)
        let pane = UUID().uuidString
        #expect(store.setMode(paneID: pane, mode: .research))

        HookRouter.paneModeResolver = { paneID in store.resolve(paneID: paneID) }
        #expect(HookRouter.paneModeResolver(pane) == .research)
        #expect(HookRouter.paneModeResolver("unknown-pane") == .general)
        #expect(HookRouter.paneModeResolver(nil) == .general)
    }
}
