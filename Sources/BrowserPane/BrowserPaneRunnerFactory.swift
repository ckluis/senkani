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
}
