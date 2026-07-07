import Foundation
import WebKit
import AppKit
import Network
import Core

/// U.2b-1b-4 — off-screen WKWebView lifecycle + 4-axis callAsyncJavaScript
/// runner. Conforms to `BrowserRunner` (the `Sources/Core/Validation/
/// BrowserRunner.swift` protocol the `BrowserValidationDispatcher` calls).
/// Child #6 wires the dispatcher's `.headless` arm to this runner; today
/// the dispatcher still returns a structured `headless_not_yet_implemented`
/// refusal for that path.
///
/// Lifecycle:
///   * Allocates an off-screen `NSWindow` (drawsBackground=false) sized
///     to a 1280x800 default content rect.
///   * Allocates a `WKWebView` with a private `WKWebViewConfiguration` —
///     the website data store is non-persistent so each run starts from
///     a clean cookie/storage baseline. The web view is added to the
///     window's content view so the responder chain is live for any
///     synthetic keyboard delivery.
///   * Per-axis dispatch reads the extracted IIFE source from
///     `Resources/playwright-runner/axes/<axis>.js` (the byte sequence
///     U.2b-1b-3 hoisted out of `runner.ts`) and feeds it to
///     `WKWebView.callAsyncJavaScript` (wrapped `return (<IIFE>);` — the
///     axis files stay IIFE expressions for Playwright's `page.evaluate`;
///     this runner branches the wrapping and awaits Promise-returning
///     axes). The parity corpus child #6 ships diffs the Playwright vs
///     WKWebView outputs against the SAME bytes.
///   * Sutton P0 — focus-order Tab walk uses the **synthetic** path:
///     a `KeyboardEvent("keydown",{key:"Tab"})` dispatched via
///     `callAsyncJavaScript` on `document.activeElement`. Decision
///     captured here: direct `NSEvent` keyDown to an off-screen
///     WKWebView does not advance focus reliably without the window
///     becoming key (which would defeat the off-screen invariant),
///     while the synthetic path drives focus via the DOM directly
///     and matches the Playwright `page.keyboard.press("Tab")` runtime
///     contract.
///   * Teardown on `tearDown()` closes the NSWindow and drops the
///     WKWebView reference. The non-persistent website data store
///     releases when no WebKit process holds it.
///
/// Result shape mirrors `PlaywrightSubprocessRunner` byte-for-byte —
/// same `PlaywrightResult` Codable, same `axes_run` ordering, same
/// `result_status` strings. Child #6 verifies parity.
///
/// Threading: `run(plan:targetURL:screenshot:)` is **synchronous** to
/// match the `BrowserRunner` protocol. Internally it bounces work to
/// the main actor (WebKit/AppKit are main-actor-isolated) and waits
/// via a `DispatchSemaphore`. Callers MUST invoke `run` from a
/// background thread — calling it on the main thread will deadlock
/// since WebKit IPC also runs on main.
public final class BrowserPaneRunner: BrowserRunner, @unchecked Sendable {

    /// Default off-screen content rect — sized large enough that
    /// LCP / layout measurements reflect realistic desktop geometry.
    public static let defaultContentRect = NSRect(x: -10_000, y: -10_000, width: 1280, height: 800)

    /// Wall-clock cap on a single axis dispatch. WKWebView normally
    /// returns within hundreds of ms for the four extracted axis
    /// bodies; the cap exists so a hung page doesn't park the run
    /// thread indefinitely.
    public static let defaultAxisTimeout: TimeInterval = 15.0

    /// Absolute path to `Resources/playwright-runner/axes/` — walks
    /// up from CWD looking for the directory, matching the resolution
    /// shape `PlaywrightSubprocessRunner.defaultRunnerPath` uses.
    public static func defaultAxesDirectory() -> URL? {
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

    /// Filenames consumed by `run(...)` — listed here so tests can
    /// assert the contract without relying on string literals
    /// scattered through the source.
    public static let axisJSFilenames: [String: String] = [
        "perf": "perf.js",
        "completeness": "completeness.js",
        "security": "security.js",
        "design": "design.js",
    ]

    private let axesDirectory: URL
    private let axisTimeout: TimeInterval
    private let contentRect: NSRect
    /// U.2b-1b-5 — Optional EgressProxy URL (e.g.
    /// `URL(string: "http://127.0.0.1:18080")`). When set, the
    /// off-screen WKWebView routes traffic through this proxy via
    /// `WKWebsiteDataStore.proxyConfigurations = [...]` (the
    /// macOS 14+ surface — note the API is `proxyConfigurations`
    /// plural, an array of `Network.ProxyConfiguration`; the
    /// acceptance text calls out `httpProxyConfiguration` which is
    /// the convenient shorthand for this array's first entry).
    /// Each `run(...)` writes a per-target same-origin allowlist
    /// to a temp JSON file (mirroring
    /// `BrowserValidationDispatcher.writeEgressOverridePolicyIfNeeded`)
    /// so the daemon can consume it via `SENKANI_EGRESS_POLICY_OVERRIDE`
    /// when child #6 wires the daemon-side handoff. nil = no proxy
    /// (direct connect; current default — keeps existing callers
    /// source-compatible).
    public let egressProxyURL: URL?

    /// U.2b-2 GUI child a-1 — dispatch target for `run(...)`.
    ///
    ///   * `.offScreen` (default; source-compatible with every U.2b-1b
    ///     caller) — allocate a private off-screen `NSWindow` + `WKWebView`
    ///     via `LifecycleHandle`, navigate to `targetURL`, evaluate the
    ///     axes, tear down. This is the `dispatch: .headless` runner.
    ///   * `.visiblePane(paneId:)` — resolve `paneId` against
    ///     `LivePaneRegistry` (fail-closed) and evaluate the axes against
    ///     that pane's ALREADY-loaded live `WKWebView` — no navigation, no
    ///     window allocation. This is the `dispatch: .pane` runner. A `nil`
    ///     `paneId` resolves to the most-recently-focused live pane.
    public enum Mode: Sendable {
        case offScreen
        case visiblePane(paneId: String?)
    }

    private let mode: Mode

    /// U.2b-2 GUI child a-1 — the pane input-lock state lives on the
    /// runner (acceptance: "lock state lives on the runner"). Guarded by
    /// `lockMutex`; the visible-pane `run(...)` drives it (lock on
    /// dispatch start, unlock on success, banner on refusal), and the GUI
    /// (`BrowserPaneView`, sibling a-2's runtime wiring) reads
    /// `lockSnapshot()` / dismisses via `dismissBanner()`.
    private var lockState = PaneLockStateMachine()
    private let lockMutex = NSLock()

    public init(
        axesDirectory: URL? = nil,
        axisTimeout: TimeInterval = BrowserPaneRunner.defaultAxisTimeout,
        contentRect: NSRect = BrowserPaneRunner.defaultContentRect,
        egressProxyURL: URL? = nil,
        mode: Mode = .offScreen
    ) {
        self.axesDirectory = axesDirectory
            ?? BrowserPaneRunner.defaultAxesDirectory()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/playwright-runner/axes")
        self.axisTimeout = axisTimeout
        self.contentRect = contentRect
        self.egressProxyURL = egressProxyURL
        self.mode = mode
    }

    // MARK: - Pane input lock (U.2b-2 GUI child a-1)

    /// Thread-safe snapshot of the lock state machine for the GUI to bind
    /// its URL-bar / nav-gesture `.disabled(...)` modifiers against.
    public func lockSnapshot() -> PaneLockStateMachine {
        lockMutex.lock(); defer { lockMutex.unlock() }
        return lockState
    }

    /// Apply a lock event under the mutex. Returns the machine's result so
    /// callers (and tests) can observe rejected edges (double dispatch,
    /// dismiss-while-active).
    @discardableResult
    public func applyLockEvent(_ event: PaneLockStateMachine.Event) -> Result<PaneLockStateMachine.State, PaneLockStateMachine.TransitionError> {
        lockMutex.lock(); defer { lockMutex.unlock() }
        return lockState.apply(event)
    }

    /// Operator dismissed the refusal banner — unlock the pane.
    @discardableResult
    public func dismissBanner() -> Result<PaneLockStateMachine.State, PaneLockStateMachine.TransitionError> {
        return applyLockEvent(.bannerDismissed)
    }

    /// U.2b-1b-5 — write the per-target same-origin allowlist to a
    /// temp JSON file in the wire format `EgressPolicy.load(from:)`
    /// reads. Returns the temp path on success, nil when
    /// `proxyURL` is unset, the target URL is malformed, or the URL
    /// is hostless (e.g. `file://`). Mirrors
    /// `BrowserValidationDispatcher.writeEgressOverridePolicyIfNeeded`
    /// in shape — exposed publicly so tests can assert the contract
    /// without driving an entire `run(...)`. Caller is responsible
    /// for cleanup via `defer { try? FileManager.default.removeItem(atPath:) }`.
    public static func writeEgressOverridePolicy(targetURL: String, proxyURL: URL?) -> String? {
        guard let proxy = proxyURL, !proxy.absoluteString.isEmpty,
              let url = URL(string: targetURL),
              let policy = EgressPolicy.sameOriginAllowlist(targetURL: url) else {
            return nil
        }
        do {
            let data = try policy.encodeWireJSON()
            let dir = NSTemporaryDirectory()
            let filename = "senkani-egress-override-\(UUID().uuidString).json"
            let path = (dir as NSString).appendingPathComponent(filename)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            return path
        } catch {
            return nil
        }
    }

    /// U.2b-1b-5 — build the `Network.ProxyConfiguration` for the
    /// off-screen WKWebView's website data store. Returns nil when
    /// `proxyURL` is unset, malformed, or missing a host/port. The
    /// HTTP CONNECT shape matches the EgressProxy daemon's listener
    /// convention (T.1a) and routes both HTTP + HTTPS through the
    /// proxy endpoint via tunneling.
    public static func makeProxyConfiguration(proxyURL: URL?) -> ProxyConfiguration? {
        guard let url = proxyURL,
              let host = url.host, !host.isEmpty else {
            return nil
        }
        let portValue = UInt16(url.port ?? 80)
        guard let port = NWEndpoint.Port(rawValue: portValue) else { return nil }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: port
        )
        return ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
    }

    // MARK: - BrowserRunner

    public func run(plan: [ValidationStep], targetURL: String, screenshot: Bool) throws -> PlaywrightResult {
        _ = screenshot
        let axesRequested = orderedAxes(plan: plan)
        guard !axesRequested.isEmpty else {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: "no_axes_requested — plan was empty"
            )
        }

        // U.2b-2 GUI child a-1 — visible-pane mode binds to the live
        // WKWebView `BrowserPaneView` registered, instead of allocating an
        // off-screen window. Fail-closed pane resolution runs FIRST.
        if case let .visiblePane(paneId) = mode {
            return runVisiblePane(axesRequested: axesRequested, paneId: paneId)
        }

        guard let url = URL(string: targetURL) else {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: "invalid_target_url — \(targetURL.prefix(120))"
            )
        }

        // U.2b-1b-5 — write the per-target same-origin allowlist to a
        // temp JSON file when an egressProxyURL is configured. Cleaned
        // up via defer regardless of run outcome (success, page-load
        // failure, axis-eval failure — all clean up).
        let egressOverridePath = BrowserPaneRunner.writeEgressOverridePolicy(
            targetURL: targetURL,
            proxyURL: egressProxyURL
        )
        defer {
            if let p = egressOverridePath {
                try? FileManager.default.removeItem(atPath: p)
            }
        }

        let lifecycle = LifecycleHandle(
            contentRect: contentRect,
            proxyConfiguration: BrowserPaneRunner.makeProxyConfiguration(proxyURL: egressProxyURL)
        )
        do {
            try lifecycle.bringUpSync()
        } catch {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: 0,
                screenshotPath: nil,
                advisory: "lifecycle_bringup_failed: \(error)"
            )
        }
        defer { lifecycle.tearDownSync() }

        do {
            try lifecycle.loadSync(url: url, timeout: axisTimeout)
        } catch {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: axesRequested,
                assertionsPassed: 0,
                assertionsFailed: axesRequested.count,
                screenshotPath: nil,
                advisory: "page_load_failed: \(error)"
            )
        }

        var assertionsPassed = 0
        var assertionsFailed = 0
        var advisories: [String] = []

        for axis in axesRequested {
            let source = loadAxisSource(axis: axis)
            switch source {
            case .failure(let message):
                assertionsFailed += 1
                advisories.append("axis=\(axis) source_unavailable: \(message)")
                continue
            case .success(let js):
                do {
                    _ = try lifecycle.evaluateSync(js: js, timeout: axisTimeout)
                    assertionsPassed += 1
                } catch {
                    assertionsFailed += 1
                    advisories.append("axis=\(axis) evaluate_failed: \(String(describing: error).prefix(160))")
                }
            }
        }

        return PlaywrightResult(
            resultStatus: assertionsFailed == 0 ? "pass" : "fail",
            axesRun: axesRequested,
            assertionsPassed: assertionsPassed,
            assertionsFailed: assertionsFailed,
            screenshotPath: nil,
            advisory: advisories.isEmpty ? nil : advisories.joined(separator: " | ")
        )
    }

    // MARK: - U.2b-2 GUI child a-1 — visible-pane run

    /// Evaluate the requested axes against the live `WKWebView` a
    /// `BrowserPaneView` registered under `paneId`. Fail-closed:
    ///   * `paneId` that is unknown / closed / (nil with no live pane) →
    ///     structured refusal, NEVER a fall-back to a different pane and
    ///     NEVER a fabricated pass.
    ///   * A second run while a dispatch is already in flight on this
    ///     runner's lock → `validation_browser_pane_busy` refusal (the
    ///     double-dispatch guard).
    /// No navigation and no window allocation — the pane is locked so the
    /// operator cannot move it out from under the axis evaluation. The
    /// Schneier guard holds: the refusal advisory carries ONLY the
    /// resolution kind + the caller-supplied `paneId`, never page text.
    private func runVisiblePane(axesRequested: [String], paneId: String?) -> PlaywrightResult {
        let registry = LivePaneRegistry.shared
        let resolution = registry.resolve(paneId: paneId)
        guard case .resolved = resolution,
              let surface = registry.surface(paneId: paneId) as? WKWebView else {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: axesRequested.count,
                screenshotPath: nil,
                advisory: "validation_browser_pane_unresolved — \(Self.resolutionRefusalReason(resolution))"
            )
        }

        // Fail-closed against double-dispatch on the same pane: a rejected
        // `.dispatchStarted` means a run is already in flight — refuse.
        if case .failure(let err) = applyLockEvent(.dispatchStarted) {
            return PlaywrightResult(
                resultStatus: "fail",
                axesRun: [],
                assertionsPassed: 0,
                assertionsFailed: axesRequested.count,
                screenshotPath: nil,
                advisory: "validation_browser_pane_busy — \(err)"
            )
        }

        var assertionsPassed = 0
        var assertionsFailed = 0
        var advisories: [String] = []
        for axis in axesRequested {
            switch loadAxisSource(axis: axis) {
            case .failure(let message):
                assertionsFailed += 1
                advisories.append("axis=\(axis) source_unavailable: \(message)")
            case .success(let js):
                do {
                    _ = try Self.evaluateOnLivePane(surface, js: js, timeout: axisTimeout)
                    assertionsPassed += 1
                } catch {
                    assertionsFailed += 1
                    advisories.append("axis=\(axis) evaluate_failed: \(String(describing: error).prefix(160))")
                }
            }
        }

        // Unlock on success; show the refusal banner (stay locked) on any
        // failure — the two acceptance-named unlock/lock edges.
        applyLockEvent(assertionsFailed == 0 ? .dispatchSucceeded : .dispatchRefused)

        return PlaywrightResult(
            resultStatus: assertionsFailed == 0 ? "pass" : "fail",
            axesRun: axesRequested,
            assertionsPassed: assertionsPassed,
            assertionsFailed: assertionsFailed,
            screenshotPath: nil,
            advisory: advisories.isEmpty ? nil : advisories.joined(separator: " | ")
        )
    }

    /// Refusal reason string for an unresolved pane. Schneier-safe: names
    /// only the resolution kind + the caller-supplied id.
    static func resolutionRefusalReason(_ resolution: LivePaneRegistry.Resolution) -> String {
        switch resolution {
        case .resolved(let id): return "resolved pane_id=\(id)"
        case .unknownPane(let id): return "unknown_pane pane_id=\(id)"
        case .closedPane(let id): return "closed_pane pane_id=\(id)"
        case .noPanes: return "no_live_pane"
        }
    }

    /// Evaluate `js` against an already-loaded live `WKWebView` on the
    /// main actor, blocking the (background) caller via a semaphore —
    /// mirrors `LifecycleHandle.evaluateSync` but against an existing pane
    /// web view rather than an off-screen one.
    static func evaluateOnLivePane(_ webView: WKWebView, js: String, timeout: TimeInterval) throws -> Any? {
        let box = WebViewBox(webView)
        let valueBox = AnyBox()
        let errorBox = ErrorBox()
        let sem = DispatchSemaphore(value: 0)
        // Mirror the off-screen `evaluate(js:)` path: wrap the axis IIFE as
        // an async-function body and await it via `callAsyncJavaScript` so a
        // Promise-returning axis (perf.js) resolves before WKWebView marshals
        // it. The legacy `evaluateJavaScript(_:completionHandler:)` hands the
        // Promise back un-awaited (WKErrorDomain Code=5, "unsupported type"),
        // failing the perf axis on every live pane. `in: .page` keeps the eval
        // in the page's own JS world, matching the prior receiver behavior.
        let body = "return (\n\(js)\n);"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                box.webView.callAsyncJavaScript(
                    body,
                    arguments: [:],
                    in: nil,          // frame: nil = main frame
                    in: .page,        // contentWorld: .page = the page's own JS world
                    completionHandler: { result in
                        switch result {
                        case .success(let value): valueBox.value = value
                        case .failure(let error): errorBox.value = error
                        }
                        sem.signal()
                    }
                )
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw RunnerError.timeout("evaluate_timeout")
        }
        if let err = errorBox.value {
            throw RunnerError.javascriptException(String(describing: err).prefix(200).description)
        }
        return valueBox.value
    }

    // MARK: - Sutton P0 — Tab walk

    /// Run the focus-order Tab walk. Decision (synthetic vs direct
    /// `NSEvent` keyDown) is captured in this method body: synthetic
    /// `KeyboardEvent` dispatch is the canonical path because direct
    /// keyDown delivery to an off-screen WKWebView requires the
    /// hosting NSWindow to become key, which defeats the off-screen
    /// invariant.
    ///
    /// Returns the stable-id sequence the Tab walk visits, in DOM
    /// order. Implementation parity: Playwright's
    /// `page.keyboard.press("Tab")` advances the document's
    /// `activeElement` exactly as a synthetic
    /// `KeyboardEvent("keydown",{key:"Tab",bubbles:true})` dispatched
    /// on `document.activeElement` (or `document.body` as a baseline).
    public func tabWalkFocusOrder(targetURL: String, steps: Int) throws -> [String] {
        guard let url = URL(string: targetURL) else {
            throw RunnerError.invalidTargetURL(targetURL)
        }
        let lifecycle = LifecycleHandle(
            contentRect: contentRect,
            proxyConfiguration: BrowserPaneRunner.makeProxyConfiguration(proxyURL: egressProxyURL)
        )
        try lifecycle.bringUpSync()
        defer { lifecycle.tearDownSync() }
        try lifecycle.loadSync(url: url, timeout: axisTimeout)
        var ids: [String] = []
        for _ in 0..<max(0, steps) {
            let js = """
            (() => {
                const ev = new KeyboardEvent('keydown', { key: 'Tab', bubbles: true, cancelable: true });
                (document.activeElement || document.body).dispatchEvent(ev);
                const el = document.activeElement;
                if (!el) return null;
                const tag = el.tagName ? el.tagName.toLowerCase() : 'unknown';
                const id = el.getAttribute && el.getAttribute('id');
                return id ? `${tag}#${id}` : tag;
            })()
            """
            let result = try lifecycle.evaluateSync(js: js, timeout: axisTimeout)
            ids.append((result as? String) ?? "?")
        }
        return ids
    }

    // MARK: - Internals

    public enum RunnerError: Error, Equatable {
        case invalidTargetURL(String)
        case axisSourceMissing(String)
        case timeout(String)
        case javascriptException(String)
    }

    /// Order the axes the way `BrowserValidationDispatcher` orders
    /// them in its `axes_run` field — alphabetical by raw value,
    /// deduplicated. Matches `PlaywrightSubprocessRunner`'s output
    /// shape so child #6's parity corpus can diff byte-for-byte.
    private func orderedAxes(plan: [ValidationStep]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for step in plan {
            let raw = step.axis.rawValue
            if seen.insert(raw).inserted {
                out.append(raw)
            }
        }
        return out.sorted()
    }

    private enum SourceLoad {
        case success(String)
        case failure(String)
    }

    private func loadAxisSource(axis: String) -> SourceLoad {
        guard let filename = BrowserPaneRunner.axisJSFilenames[axis] else {
            return .failure("unknown_axis=\(axis)")
        }
        let url = axesDirectory.appendingPathComponent(filename)
        do {
            let str = try String(contentsOf: url, encoding: .utf8)
            return .success(str)
        } catch {
            return .failure("read_failed path=\(url.path) error=\(error)")
        }
    }
}

// MARK: - Lifecycle handle

/// Thread-safe wrapper around the off-screen NSWindow + WKWebView
/// pair. The window + web view are owned by a `@MainActor`-isolated
/// `LifecycleState` so all AppKit/WebKit mutation happens on main;
/// the public `*Sync` API blocks the calling thread (which MUST be
/// a background thread — main-thread callers deadlock) via a
/// `DispatchSemaphore`.
private final class LifecycleHandle: @unchecked Sendable {
    private let contentRect: NSRect
    private let proxyConfiguration: ProxyConfiguration?
    private let lock = NSLock()
    private var state: LifecycleState?

    init(contentRect: NSRect, proxyConfiguration: ProxyConfiguration? = nil) {
        self.contentRect = contentRect
        self.proxyConfiguration = proxyConfiguration
    }

    func bringUpSync() throws {
        let rect = contentRect
        let proxy = proxyConfiguration
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let state = LifecycleState(contentRect: rect, proxyConfiguration: proxy)
            state.bringUp()
            self.lock.lock()
            self.state = state
            self.lock.unlock()
            sem.signal()
        }
        sem.wait()
    }

    func tearDownSync() {
        lock.lock()
        let st = state
        state = nil
        lock.unlock()
        guard let st else { return }
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            st.tearDown()
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 5)
    }

    func loadSync(url: URL, timeout: TimeInterval) throws {
        lock.lock()
        let st = state
        lock.unlock()
        guard let st else {
            throw BrowserPaneRunner.RunnerError.timeout("lifecycle_not_brought_up")
        }
        let box = ErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            st.load(url: url) { err in
                box.value = err
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw BrowserPaneRunner.RunnerError.timeout("page_load_timeout url=\(url.absoluteString.prefix(120))")
        }
        if let err = box.value {
            throw err
        }
    }

    func evaluateSync(js: String, timeout: TimeInterval) throws -> Any? {
        lock.lock()
        let st = state
        lock.unlock()
        guard let st else {
            throw BrowserPaneRunner.RunnerError.timeout("lifecycle_not_brought_up")
        }
        let valueBox = AnyBox()
        let errorBox = ErrorBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            st.evaluate(js: js) { value, err in
                valueBox.value = value
                errorBox.value = err
                sem.signal()
            }
        }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw BrowserPaneRunner.RunnerError.timeout("evaluate_timeout")
        }
        if let err = errorBox.value {
            throw BrowserPaneRunner.RunnerError.javascriptException(String(describing: err).prefix(200).description)
        }
        return valueBox.value
    }
}

/// `Error?` box for completion-handler error transfer. Mutation is
/// guarded by happens-before on the `DispatchSemaphore.signal()`;
/// `@unchecked Sendable` is the hand-vouched contract.
private final class ErrorBox: @unchecked Sendable {
    var value: Error?
}

/// `Any?` box for `evaluateJavaScript` result transfer.
private final class AnyBox: @unchecked Sendable {
    var value: Any?
}

/// U.2b-2 GUI child a-1 — hand-vouched Sendable box carrying a live
/// (non-Sendable) `WKWebView` across the `DispatchQueue.main.async`
/// boundary in `evaluateOnLivePane`. The web view is only ever touched
/// inside `MainActor.assumeIsolated`, so the hand-off is safe.
private final class WebViewBox: @unchecked Sendable {
    let webView: WKWebView
    init(_ webView: WKWebView) { self.webView = webView }
}

/// Main-actor isolated owner of the NSWindow + WKWebView pair. All
/// AppKit/WebKit mutation lives here.
@MainActor
private final class LifecycleState {
    private let contentRect: NSRect
    private let proxyConfiguration: ProxyConfiguration?
    private var window: NSWindow?
    private var webView: WKWebView?
    private var navigationDelegate: NavDelegate?

    init(contentRect: NSRect, proxyConfiguration: ProxyConfiguration? = nil) {
        self.contentRect = contentRect
        self.proxyConfiguration = proxyConfiguration
    }

    func bringUp() {
        let config = WKWebViewConfiguration()
        let dataStore: WKWebsiteDataStore = .nonPersistent()
        // U.2b-1b-5 — when an EgressProxy URL was supplied, set the
        // website data store's proxyConfigurations array so WKWebView
        // traffic tunnels through the proxy. macOS 14+ surface.
        if let proxy = proxyConfiguration {
            dataStore.proxyConfigurations = [proxy]
        }
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: contentRect, configuration: config)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = webView
        window.setFrame(contentRect, display: false)
        let delegate = NavDelegate()
        webView.navigationDelegate = delegate
        self.webView = webView
        self.window = window
        self.navigationDelegate = delegate
    }

    func tearDown() {
        webView?.navigationDelegate = nil
        window?.contentView = nil
        window?.close()
        webView = nil
        navigationDelegate = nil
        window = nil
    }

    func load(url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard let webView = webView, let delegate = navigationDelegate else {
            completion(BrowserPaneRunner.RunnerError.timeout("lifecycle_not_brought_up"))
            return
        }
        delegate.onFinished = completion
        let req = URLRequest(url: url)
        webView.load(req)
    }

    /// Evaluate an axis IIFE-expression body against the loaded page and
    /// hand the marshaled result back on the main actor.
    ///
    /// Uses `callAsyncJavaScript` (macOS 11+), NOT the legacy
    /// `evaluateJavaScript(_:completionHandler:)`. `callAsyncJavaScript`
    /// runs the source as the body of an *async function* and awaits its
    /// returned value, so a Promise-returning axis resolves BEFORE WebKit
    /// marshals it. `Resources/playwright-runner/axes/perf.js` returns
    /// `new Promise(...)` resolving to `{inp_ms, lcp_ms}`; the legacy API
    /// handed that Promise object straight back and WKWebView could not
    /// marshal it (`WKErrorDomain Code=5`, "unsupported type"), failing
    /// the perf axis on every page. See
    /// `browserpane-runner-evaluatejs-no-promise-await-2026-07-05`.
    ///
    /// **Per-runner wrapping (branch, not shared edit).** The axis `.js`
    /// files stay IIFE *expressions* so Playwright's `page.evaluate(STRING)`
    /// keeps working unchanged; only this runner adapts them.
    /// `callAsyncJavaScript` wants a function *body* (statements), so the
    /// IIFE expression is wrapped `return (<expr>);`. `return`ing a Promise
    /// from an async body awaits it; `return`ing a sync value passes it
    /// through — so ALL axes route through this ONE path uniformly (sync:
    /// completeness/design/security; async: perf). A JS throw or a Promise
    /// rejection inside the body surfaces as `.failure` → the caller's
    /// `RunnerError.javascriptException`, exactly as the legacy path did.
    func evaluate(js: String, completion: @escaping @MainActor (Any?, Error?) -> Void) {
        guard let webView = webView else {
            completion(nil, BrowserPaneRunner.RunnerError.timeout("lifecycle_not_brought_up"))
            return
        }
        // Wrap the axis IIFE expression as an async-function body. The
        // parens keep leading `//` file-header comments inside a single
        // returned expression; the awaited result (Promise-resolved or
        // sync) is what WKWebView marshals.
        let body = "return (\n\(js)\n);"
        webView.callAsyncJavaScript(
            body,
            arguments: [:],
            in: nil,          // frame: nil = main frame
            in: .page,        // contentWorld: .page = the page's own JS world
            completionHandler: { result in
                switch result {
                case .success(let value):
                    completion(value, nil)
                case .failure(let error):
                    completion(nil, error)
                }
            }
        )
    }
}

/// Minimal navigation delegate — fires `onFinished(nil)` on success
/// and `onFinished(error)` on failure so `LifecycleState.load(...)`
/// can gate on the round-trip.
@MainActor
private final class NavDelegate: NSObject, WKNavigationDelegate {
    var onFinished: ((Error?) -> Void)?

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            onFinished?(nil)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            onFinished?(error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            onFinished?(error)
        }
    }
}
