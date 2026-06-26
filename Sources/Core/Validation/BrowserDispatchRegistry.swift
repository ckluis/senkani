import Foundation

/// U.2b-1b-6 — late-bound factory slot the `BrowserValidationDispatcher`
/// `.headless` arm reads when CLI / MCP callers ask for the off-screen
/// WKWebView runner. The concrete `BrowserPaneRunner` lives in the
/// SenkaniApp executable target (WebKit + AppKit imports), so neither
/// `Sources/CLI` nor `Sources/MCP` can construct it directly. SenkaniApp
/// registers a factory at startup; CLI / MCP look it up at dispatch
/// time.
///
/// When no factory is registered (standalone CLI invocation that never
/// loads SenkaniApp), `BrowserValidationDispatcher` falls back to the
/// `headless_not_yet_implemented` structured refusal — the same shape
/// callers were wired against under U.2b-1a, so the wiring is purely
/// additive.
///
/// The registry is global-by-design: there is one off-screen WKWebView
/// runner per process, configured at startup. The lock is held only
/// while reading / writing the static slot; the factory closure is
/// invoked OUTSIDE the lock so a long-running runner does not block
/// concurrent registry reads.
public enum BrowserDispatchRegistry {

    /// Factory closure shape. SenkaniApp registers a closure that
    /// constructs a fresh `BrowserPaneRunner` (or any `BrowserRunner`
    /// conformer) for the given egress proxy URL. The dispatcher
    /// wraps the returned runner's `run(plan:targetURL:screenshot:)`
    /// in the closure shape the `Runner` typealias requires.
    ///
    /// Returning `nil` from the factory is allowed and treated
    /// identically to "factory not registered" — the dispatcher falls
    /// back to the structured refusal.
    public typealias HeadlessRunnerFactory = @Sendable (_ egressProxyURL: String?) -> (any BrowserRunner)?

    /// U.2b-2 child (b headless seam) — factory shape for the VISIBLE-pane
    /// runner. Identical signature to `HeadlessRunnerFactory`: SenkaniApp
    /// registers a closure that constructs (or returns a shared) visible
    /// `BrowserPaneRunner` for the given egress proxy URL. Returning `nil`
    /// is allowed and treated identically to "factory not registered" —
    /// the dispatcher then fails CLOSED with the
    /// `validation_browser_pane_no_runner` structured refusal (NEVER a
    /// fabricated pass). The concrete visible-pane runner lives in the
    /// SenkaniApp executable target (WebKit + AppKit), so neither
    /// `Sources/CLI` nor `Sources/MCP` can construct it directly; today no
    /// host registers a pane factory (the GUI/Cowork half lands later), so
    /// CLI / MCP `.pane` dispatches resolve to the structured refusal.
    public typealias PaneRunnerFactory = @Sendable (_ egressProxyURL: String?) -> (any BrowserRunner)?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _factory: HeadlessRunnerFactory?
    nonisolated(unsafe) private static var _paneFactory: PaneRunnerFactory?

    /// Register (or replace) the factory. SenkaniApp calls this once
    /// at app boot. Passing `nil` clears the slot — useful in tests
    /// that need to exercise the "no factory registered" fallback.
    public static func registerHeadlessRunnerFactory(_ factory: HeadlessRunnerFactory?) {
        lock.lock()
        defer { lock.unlock() }
        _factory = factory
    }

    /// Returns the registered factory, or `nil` if none was set.
    public static func headlessRunnerFactory() -> HeadlessRunnerFactory? {
        lock.lock()
        defer { lock.unlock() }
        return _factory
    }

    /// Convenience: construct a `BrowserValidationDispatcher.Runner`
    /// closure that delegates to the registered factory. Returns
    /// `nil` when no factory is registered — the dispatcher then
    /// falls back to the structured refusal.
    ///
    /// The returned closure constructs a fresh runner per `dispatch`
    /// call; callers that want to reuse a single runner across many
    /// dispatches should register a factory that returns a shared
    /// instance.
    public static func makeHeadlessRunnerClosure(egressProxyURL: String?) -> BrowserValidationDispatcher.Runner? {
        guard let factory = headlessRunnerFactory() else { return nil }
        return { plan, targetURL, screenshot, _ in
            guard let runner = factory(egressProxyURL) else {
                throw PlaywrightRunnerError.validationBrowserMissing(
                    installHint: "register a BrowserDispatchRegistry.headlessRunnerFactory at app startup"
                )
            }
            return try runner.run(plan: plan, targetURL: targetURL, screenshot: screenshot)
        }
    }

    /// U.2b-2 child (b headless seam) — register (or replace) the visible-
    /// pane factory. SenkaniApp's GUI/Cowork half calls this once the
    /// visible BrowserPane runner is available. Passing `nil` clears the
    /// slot — useful in tests exercising the "no pane runner registered"
    /// fail-closed fallback. Same lock idiom as the headless slot; the
    /// factory closure is invoked OUTSIDE the lock at dispatch time.
    public static func registerPaneRunnerFactory(_ factory: PaneRunnerFactory?) {
        lock.lock()
        defer { lock.unlock() }
        _paneFactory = factory
    }

    /// Returns the registered visible-pane factory, or `nil` if none was set.
    public static func paneRunnerFactory() -> PaneRunnerFactory? {
        lock.lock()
        defer { lock.unlock() }
        return _paneFactory
    }

    /// Convenience: construct a `BrowserValidationDispatcher.Runner`
    /// closure that delegates to the registered VISIBLE-pane factory.
    /// Returns `nil` when no factory is registered — the dispatcher then
    /// fails CLOSED with the `validation_browser_pane_no_runner` refusal
    /// (the ONLY way `.pane` yields a non-refusal Response is an
    /// explicitly-registered, non-nil pane runner).
    ///
    /// Exactly mirrors `makeHeadlessRunnerClosure` so the dispatcher's
    /// `.pane` arm can invoke the returned closure byte-for-byte the same
    /// way it invokes the headless one.
    public static func makePaneRunnerClosure(egressProxyURL: String?) -> BrowserValidationDispatcher.Runner? {
        guard let factory = paneRunnerFactory() else { return nil }
        return { plan, targetURL, screenshot, _ in
            guard let runner = factory(egressProxyURL) else {
                throw PlaywrightRunnerError.validationBrowserMissing(
                    installHint: "register a BrowserDispatchRegistry.paneRunnerFactory once the visible pane is available"
                )
            }
            return try runner.run(plan: plan, targetURL: targetURL, screenshot: screenshot)
        }
    }
}
