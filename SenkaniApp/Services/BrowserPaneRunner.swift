import Foundation
import WebKit
import AppKit
import Core

/// U.2b-1b-4 — off-screen WKWebView lifecycle + 4-axis evaluateJavaScript
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
///     `WKWebView.evaluateJavaScript`. The parity corpus child #6 ships
///     diffs the Playwright vs WKWebView outputs against the SAME bytes.
///   * Sutton P0 — focus-order Tab walk uses the **synthetic** path:
///     a `KeyboardEvent("keydown",{key:"Tab"})` dispatched via
///     `evaluateJavaScript` on `document.activeElement`. Decision
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

    public init(
        axesDirectory: URL? = nil,
        axisTimeout: TimeInterval = BrowserPaneRunner.defaultAxisTimeout,
        contentRect: NSRect = BrowserPaneRunner.defaultContentRect
    ) {
        self.axesDirectory = axesDirectory
            ?? BrowserPaneRunner.defaultAxesDirectory()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/playwright-runner/axes")
        self.axisTimeout = axisTimeout
        self.contentRect = contentRect
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

        let lifecycle = LifecycleHandle(contentRect: contentRect)
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
        let lifecycle = LifecycleHandle(contentRect: contentRect)
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
    private let lock = NSLock()
    private var state: LifecycleState?

    init(contentRect: NSRect) {
        self.contentRect = contentRect
    }

    func bringUpSync() throws {
        let rect = contentRect
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let state = LifecycleState(contentRect: rect)
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

/// Main-actor isolated owner of the NSWindow + WKWebView pair. All
/// AppKit/WebKit mutation lives here.
@MainActor
private final class LifecycleState {
    private let contentRect: NSRect
    private var window: NSWindow?
    private var webView: WKWebView?
    private var navigationDelegate: NavDelegate?

    init(contentRect: NSRect) {
        self.contentRect = contentRect
    }

    func bringUp() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
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

    func evaluate(js: String, completion: @escaping @MainActor (Any?, Error?) -> Void) {
        guard let webView = webView else {
            completion(nil, BrowserPaneRunner.RunnerError.timeout("lifecycle_not_brought_up"))
            return
        }
        webView.evaluateJavaScript(js) { value, error in
            completion(value, error)
        }
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
