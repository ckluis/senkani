import Foundation
import Core

/// U.2b-1b-6 — registers `BrowserPaneRunner` as the off-screen WKWebView
/// runner the `BrowserValidationDispatcher.headless` arm invokes.
///
/// Called by `SenkaniApp/App/main.swift` at process boot — once per
/// process, before either the GUI or the MCP-server mode runs. Standalone
/// CLI / `senkani-mcp` binaries never link this target so the factory
/// stays nil there, and the dispatcher falls back to the structured
/// `headless_not_yet_implemented` refusal (Russell back-compat).
///
/// Construction is cheap (state lives on `BrowserPaneRunner.shared`-style
/// lazy lifecycle inside `run(...)`), so the factory returns a fresh
/// `BrowserPaneRunner` per dispatch. The runner's window allocation is
/// deferred to `LifecycleHandle.bringUpSync()` inside the run, so a
/// no-traffic process pays no GUI tax for the registration itself.
public enum BrowserPaneRunnerFactory {

    /// Idempotent — safe to call from multiple boot paths.
    public static func register() {
        BrowserDispatchRegistry.registerHeadlessRunnerFactory { egressProxyURL in
            let url = egressProxyURL.flatMap { URL(string: $0) }
            return BrowserPaneRunner(egressProxyURL: url)
        }
    }

    /// U.2b-2 GUI child a-1 — register the VISIBLE-pane runner factory so
    /// `dispatch: .pane` stops fail-closed-refusing end-to-end when the app
    /// is running. Mirrors `register()` (which wires the off-screen
    /// `.headless` arm above) but constructs a `.visiblePane` runner that
    /// binds to the live `WKWebView` a `BrowserPaneView` publishes into
    /// `LivePaneRegistry`.
    ///
    /// This writes ONLY the Core-side `_paneFactory` slot via
    /// `registerPaneRunnerFactory` — it does NOT touch the headless slot,
    /// so `dispatch: .headless` behavior is unchanged (the two slots are
    /// independent; the dispatcher's `.headless` arm keeps reading the
    /// headless factory registered by `register()`).
    ///
    /// The `PaneRunnerFactory` closure signature carries no `pane_id`, so
    /// the constructed runner resolves the most-recently-focused live pane
    /// (`paneId: nil`). A specific `pane_id`'s resolution is fail-closed in
    /// `LivePaneRegistry` (unknown / closed → refuse, never a different
    /// pane). Idempotent — safe to call from multiple boot paths.
    ///
    /// Lives in the `BrowserPane` library (no SwiftUI import), so the boot
    /// call in `SenkaniApp/App/main.swift` pulls no SwiftUI into the
    /// separate CLI / `senkani-mcp` binaries (which never link SenkaniApp
    /// or BrowserPane's pane surface).
    public static func registerPaneRunner() {
        BrowserDispatchRegistry.registerPaneRunnerFactory { egressProxyURL in
            let url = egressProxyURL.flatMap { URL(string: $0) }
            return BrowserPaneRunner(egressProxyURL: url, mode: .visiblePane(paneId: nil))
        }
    }
}
