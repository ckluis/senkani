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
/// U.2b-1b-6 — assertion-evaluation parity. `run(...)` no longer
/// smoke-tests that each axis's JS merely executes; it CAPTURES each
/// axis's measurement, decodes it into the same measurement type the
/// subprocess arm decodes, and routes it through the same shared Swift
/// evaluators (`PerfAxis.evaluate` / `CompletenessAxis.evaluate`) —
/// `aggregateAxisResults(...)` folds the counts exactly as `runner.ts`'s
/// `main()` does (perf + completeness counted; security + design measured
/// but uncounted, matching the subprocess arm which has no production
/// `evaluateSecurity` / `evaluateDesign`). `result_status` is computed
/// from ACTUAL assertion outcomes, so a genuinely-failing page (e.g. a
/// missing `<meta name="description">`) can no longer false-pass. See
/// `process-gap-u2b-1b-6-headless-arm-skips-assertion-evaluation-2026-07-07`.
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

    /// U.2b-2 GUI child a-2 — the pane input-lock state NO LONGER lives on
    /// the runner. The factory builds a FRESH `BrowserPaneRunner` per
    /// dispatch, so a runner-local lock was discarded after every run (and
    /// a fresh runner's `.unlocked` machine could never catch a genuine
    /// double dispatch). The visible-pane run now drives the process-global
    /// `PaneDispatchStateStore.shared`, keyed by the RESOLVED `pane_id` — the
    /// store outlives the per-dispatch runner and is what `BrowserPaneView`
    /// observes. `PaneLockStateMachine` remains the sole transition
    /// authority; the store delegates to it (a-1's re-audit option (b)).

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

        // U.2b-1b-6 — CAPTURE each axis's measurement (stop discarding it),
        // decode it into the SAME measurement type the subprocess arm decodes,
        // and route it through the SAME shared Swift evaluators. The prior
        // implementation ran each axis's JS, `_ = try`-discarded the result,
        // counted 1 pass/axis when the JS merely executed, and false-passed on
        // genuinely-failing pages. See
        // `process-gap-u2b-1b-6-headless-arm-skips-assertion-evaluation-2026-07-07`.
        var perfMeasurement: PerfMeasurement?
        var completenessMeasurement: CompletenessMeasurement?
        var securityMeasurement: SecurityMeasurement?
        var designMeasurement: DesignMeasurement?

        for axis in axesRequested {
            let js: String
            switch loadAxisSource(axis: axis) {
            case .failure(let message):
                // Axis source unavailable = a measurement error. runner.ts's
                // page.evaluate throwing surfaces as a whole-run browser
                // failure (fail / 0 / 0); mirror that rather than fabricating
                // a per-axis pass/fail from an I/O error.
                return BrowserPaneRunner.measurementFailure(
                    axesRequested,
                    "axis=\(axis) source_unavailable: \(message)"
                )
            case .success(let source):
                js = source
            }

            let value: Any?
            do {
                value = try lifecycle.evaluateSync(js: js, timeout: axisTimeout)
            } catch {
                // Measurement JS threw / timed out — mirror runner.ts's
                // browser-exception path (fail / 0 / 0 for the whole run), NOT
                // a per-axis +1 failed. The page-load falsifier above is
                // unaffected (it returns before reaching this loop).
                return BrowserPaneRunner.measurementFailure(
                    axesRequested,
                    "axis=\(axis) evaluate_failed: \(String(describing: error).prefix(160))"
                )
            }

            switch axis {
            case ValidationAxes.perf.rawValue:
                guard let m = BrowserPaneRunner.decodeJSONMeasurement(PerfMeasurement.self, from: value) else {
                    return BrowserPaneRunner.measurementFailure(axesRequested, "axis=perf measurement_decode_failed")
                }
                perfMeasurement = m
            case ValidationAxes.completeness.rawValue:
                guard let dom = BrowserPaneRunner.decodeJSONMeasurement(CompletenessDOM.self, from: value) else {
                    return BrowserPaneRunner.measurementFailure(axesRequested, "axis=completeness measurement_decode_failed")
                }
                // HEAD-probe each same-origin link for its status code — the
                // auxiliary step runner.ts performs via page.request.fetch
                // outside page.evaluate (completeness.js returns hrefs only).
                let internalLinks = BrowserPaneRunner.probeInternalLinks(dom.sameOriginLinks, timeout: axisTimeout)
                completenessMeasurement = CompletenessMeasurement(
                    title: dom.title,
                    metaDescription: dom.metaDescription,
                    internalLinks: internalLinks,
                    images: dom.images
                )
            case ValidationAxes.security.rawValue:
                // security.js emits the SecurityMeasurement shape directly.
                securityMeasurement = BrowserPaneRunner.decodeJSONMeasurement(SecurityMeasurement.self, from: value)
            case ValidationAxes.design.rawValue:
                // design.js emits phase-1 { interactive_targets, dom_focus_order };
                // the Tab-walk (tab_focus_order) is a separate off-screen
                // navigation (see tabWalkFocusOrder) the parity counts do not
                // depend on, so it is left empty here.
                if let dom = BrowserPaneRunner.decodeJSONMeasurement(DesignDOM.self, from: value) {
                    designMeasurement = DesignMeasurement(
                        interactiveTargets: dom.interactiveTargets,
                        domFocusOrder: dom.domFocusOrder,
                        tabFocusOrder: []
                    )
                }
            default:
                break
            }
        }

        let aggregate = BrowserPaneRunner.aggregateAxisResults(
            axesRun: axesRequested,
            perf: perfMeasurement,
            perfExpected: BrowserPaneRunner.parsePerfExpected(plan: plan),
            completeness: completenessMeasurement,
            security: securityMeasurement,
            design: designMeasurement
        )

        return PlaywrightResult(
            resultStatus: aggregate.resultStatus,
            axesRun: axesRequested,
            assertionsPassed: aggregate.assertionsPassed,
            assertionsFailed: aggregate.assertionsFailed,
            screenshotPath: nil,
            advisory: aggregate.advisory,
            securityMeasurement: aggregate.securityMeasurement,
            designMeasurement: aggregate.designMeasurement
        )
    }

    // MARK: - U.2b-2 GUI child a-2 — visible-pane run

    /// Evaluate the requested axes against the live `WKWebView` a
    /// `BrowserPaneView` registered under `paneId`. Fail-closed:
    ///   * `paneId` that is unknown / closed / (nil with no live pane) →
    ///     structured refusal, NEVER a fall-back to a different pane and
    ///     NEVER a fabricated pass.
    ///   * A second run while a dispatch is already in flight on the SAME
    ///     resolved pane → `validation_browser_pane_busy` refusal (the
    ///     double-dispatch guard, now checked against the persistent
    ///     `PaneDispatchStateStore`, not a throwaway per-runner lock).
    /// No navigation and no window allocation — the pane is locked so the
    /// operator cannot move it out from under the axis evaluation. The
    /// Schneier guard holds: the refusal advisory carries ONLY the
    /// resolution kind + the caller-supplied `paneId`, never page text; and
    /// the banner the store surfaces carries ONLY `failingAxis` +
    /// `fixtureId` (`PaneRefusal`'s two fields), never captured output.
    ///
    /// Lock/banner outcome is written into `PaneDispatchStateStore.shared`
    /// keyed by the RESOLVED concrete `pane_id` (so `paneId: nil` — the
    /// most-recently-focused convenience — still keys the store by the real
    /// id, which is what `BrowserPaneView` observes). The store outlives
    /// this per-dispatch runner instance, closing the a-1 statelessness gap.
    private func runVisiblePane(axesRequested: [String], paneId: String?) -> PlaywrightResult {
        let registry = LivePaneRegistry.shared
        let resolution = registry.resolve(paneId: paneId)
        guard case .resolved(let resolvedId) = resolution,
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

        let store = PaneDispatchStateStore.shared

        // Lock on dispatch start via the SHARED, pane-keyed store. Fail-closed
        // against double-dispatch: a rejected `.dispatchStarted` means a run
        // is already in flight on this pane — refuse (busy), do not run twice.
        if case .failure(let err) = store.dispatchStarted(paneId: resolvedId) {
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
        var firstFailingAxis: String?
        for axis in axesRequested {
            switch loadAxisSource(axis: axis) {
            case .failure(let message):
                assertionsFailed += 1
                if firstFailingAxis == nil { firstFailingAxis = axis }
                advisories.append("axis=\(axis) source_unavailable: \(message)")
            case .success(let js):
                do {
                    _ = try Self.evaluateOnLivePane(surface, js: js, timeout: axisTimeout)
                    assertionsPassed += 1
                } catch {
                    assertionsFailed += 1
                    if firstFailingAxis == nil { firstFailingAxis = axis }
                    advisories.append("axis=\(axis) evaluate_failed: \(String(describing: error).prefix(160))")
                }
            }
        }

        // Unlock on success; surface the refusal banner (stay locked) on any
        // failure — the two acceptance-named unlock/lock edges, both written
        // into the store so the observing pane view reflects them. The banner
        // payload is pinned to the two Schneier-safe identifiers: the first
        // failing axis + the resolved pane_id as the fixture the refusal is
        // scoped to (an opaque, page-content-free id).
        if assertionsFailed == 0 {
            store.dispatchSucceeded(paneId: resolvedId)
        } else {
            store.dispatchRefused(
                paneId: resolvedId,
                refusal: PaneDispatchStateStore.PaneRefusal(
                    failingAxis: firstFailingAxis ?? "unknown",
                    fixtureId: resolvedId
                )
            )
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

    // MARK: - U.2b-1b-6 — measurement decode + shared-evaluator aggregation

    /// Aggregated headless-arm outcome. Populated by
    /// `aggregateAxisResults(...)` and copied into the returned
    /// `PlaywrightResult` by `run(...)`.
    public struct HeadlessAggregate: Sendable, Equatable {
        public let resultStatus: String
        public let assertionsPassed: Int
        public let assertionsFailed: Int
        public let advisory: String?
        public let securityMeasurement: SecurityMeasurement?
        public let designMeasurement: DesignMeasurement?

        public init(
            resultStatus: String,
            assertionsPassed: Int,
            assertionsFailed: Int,
            advisory: String?,
            securityMeasurement: SecurityMeasurement?,
            designMeasurement: DesignMeasurement?
        ) {
            self.resultStatus = resultStatus
            self.assertionsPassed = assertionsPassed
            self.assertionsFailed = assertionsFailed
            self.advisory = advisory
            self.securityMeasurement = securityMeasurement
            self.designMeasurement = designMeasurement
        }
    }

    /// PARITY CONTRACT (U.2b-1b-6). Mirrors `runner.ts` `main()` assertion
    /// aggregation so the off-screen WKWebView arm produces byte-identical
    /// `result_status` / `assertions_passed` / `assertions_failed` to the
    /// `PlaywrightSubprocessRunner` arm for the same measurement inputs.
    ///
    /// The subprocess reference (`Resources/playwright-runner/runner.ts`)
    /// folds assertion counts from **perf + completeness ONLY** — it
    /// *measures* security + design (attaching the payload to
    /// `security_measurement` / `design_measurement`) but never evaluates
    /// their assertions into the counts (there is no production caller of
    /// `SecurityAxis.evaluate` / `DesignAxis.evaluate`; runner.ts has no
    /// `evaluateSecurity` / `evaluateDesign`). To keep the two arms
    /// byte-identical this aggregator does the same: perf + completeness route
    /// through the shared Swift `PerfAxis.evaluate` / `CompletenessAxis.evaluate`
    /// (whose per-assertion pass/fail decisions match runner.ts's
    /// `evaluatePerf` / `evaluateCompleteness` row-for-row), while security +
    /// design are captured-but-uncounted.
    ///
    /// `result_status` = `assertions_failed == 0 ? "pass"
    ///                   : (assertions_passed == 0 ? "fail" : "partial")`,
    /// exactly matching runner.ts — computed from ACTUAL assertion outcomes,
    /// never from whether the axis JS threw. A completeness measurement with a
    /// missing `<meta name="description">` can therefore no longer false-pass.
    public static func aggregateAxisResults(
        axesRun: [String],
        perf: PerfMeasurement?,
        perfExpected: PerfExpected?,
        completeness: CompletenessMeasurement?,
        security: SecurityMeasurement?,
        design: DesignMeasurement?
    ) -> HeadlessAggregate {
        var passed = 0
        var failed = 0
        var advisories: [String] = []

        func fold(_ rows: [AssertionResult]) {
            for row in rows {
                if row.passed {
                    passed += 1
                } else {
                    failed += 1
                    if let advisory = row.advisory {
                        advisories.append("\(row.assertionId): \(advisory)")
                    }
                }
            }
        }

        if axesRun.contains(ValidationAxes.perf.rawValue), let perf {
            fold(PerfAxis.evaluate(measurement: perf, expected: perfExpected))
        }
        if axesRun.contains(ValidationAxes.completeness.rawValue), let completeness {
            fold(CompletenessAxis.evaluate(measurement: completeness))
        }
        // security + design: measured + attached, NOT folded into the counts —
        // parity with runner.ts (see contract note above).

        let resultStatus = failed == 0 ? "pass" : (passed == 0 ? "fail" : "partial")
        return HeadlessAggregate(
            resultStatus: resultStatus,
            assertionsPassed: passed,
            assertionsFailed: failed,
            advisory: advisories.isEmpty ? nil : advisories.joined(separator: " | "),
            securityMeasurement: axesRun.contains(ValidationAxes.security.rawValue) ? security : nil,
            designMeasurement: axesRun.contains(ValidationAxes.design.rawValue) ? design : nil
        )
    }

    /// Phase-1 completeness DOM shape returned by `axes/completeness.js`
    /// (`{ title, metaDescription, sameOriginLinks, images }`). The
    /// `internal_links` status codes are resolved afterward by
    /// `probeInternalLinks(...)`, mirroring runner.ts's
    /// `measureCompleteness` HEAD-probe loop.
    public struct CompletenessDOM: Decodable, Sendable, Equatable {
        public let title: String?
        public let metaDescription: String?
        public let sameOriginLinks: [String]
        public let images: [CompletenessMeasurement.ImageElement]

        enum CodingKeys: String, CodingKey {
            case title
            case metaDescription
            case sameOriginLinks
            case images
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.title = try c.decodeIfPresent(String.self, forKey: .title)
            self.metaDescription = try c.decodeIfPresent(String.self, forKey: .metaDescription)
            self.sameOriginLinks = try c.decodeIfPresent([String].self, forKey: .sameOriginLinks) ?? []
            self.images = try c.decodeIfPresent([CompletenessMeasurement.ImageElement].self, forKey: .images) ?? []
        }

        public init(
            title: String?,
            metaDescription: String?,
            sameOriginLinks: [String],
            images: [CompletenessMeasurement.ImageElement]
        ) {
            self.title = title
            self.metaDescription = metaDescription
            self.sameOriginLinks = sameOriginLinks
            self.images = images
        }
    }

    /// Phase-1 design DOM shape returned by `axes/design.js`
    /// (`{ interactive_targets, dom_focus_order }`). `tab_focus_order` is a
    /// separate off-screen Tab-walk (see `tabWalkFocusOrder`) and is absent
    /// from this payload; the parity counts do not consume design assertions,
    /// so the attached `DesignMeasurement` carries an empty tab-walk.
    public struct DesignDOM: Decodable, Sendable, Equatable {
        public let interactiveTargets: [DesignMeasurement.InteractiveTarget]
        public let domFocusOrder: [String]

        enum CodingKeys: String, CodingKey {
            case interactiveTargets = "interactive_targets"
            case domFocusOrder = "dom_focus_order"
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.interactiveTargets = try c.decodeIfPresent([DesignMeasurement.InteractiveTarget].self, forKey: .interactiveTargets) ?? []
            self.domFocusOrder = try c.decodeIfPresent([String].self, forKey: .domFocusOrder) ?? []
        }

        public init(interactiveTargets: [DesignMeasurement.InteractiveTarget], domFocusOrder: [String]) {
            self.interactiveTargets = interactiveTargets
            self.domFocusOrder = domFocusOrder
        }
    }

    /// Decode a WKWebView `callAsyncJavaScript` marshaled value (an
    /// `NSDictionary` / `NSArray` / `NSNumber` / `NSString` / `NSNull` tree)
    /// into a Codable measurement type by round-tripping through
    /// `JSONSerialization` → `JSONDecoder`. Returns nil when the value is
    /// absent, not a JSON object, or does not match the target shape.
    public static func decodeJSONMeasurement<T: Decodable>(_ type: T.Type, from value: Any?) -> T? {
        guard let value, JSONSerialization.isValidJSONObject(value) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Parse the `perf` step's `expected` JSON (`{ inp_ms, lcp_ms }`) into a
    /// `PerfExpected`, mirroring runner.ts's `parsePerfExpected`. Returns nil
    /// when there is no perf step, no `expected`, or the JSON is malformed —
    /// `PerfAxis.evaluate` then falls back to the Web-Vitals defaults.
    public static func parsePerfExpected(plan: [ValidationStep]) -> PerfExpected? {
        guard let step = plan.first(where: { $0.axis == .perf }),
              let expected = step.expected,
              let data = expected.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(PerfExpected.self, from: data)
    }

    /// HEAD-probe each same-origin link for its status code, mirroring
    /// runner.ts's `measureCompleteness` (`page.request.fetch(href,
    /// { method: "HEAD", failOnStatusCode: false })`). A network error or a
    /// non-HTTP response yields `status_code: nil`, which the shared
    /// `CompletenessAxis` evaluator treats as a failed link — same as
    /// runner.ts's `(status_code ?? 999) >= 400`.
    static func probeInternalLinks(_ hrefs: [String], timeout: TimeInterval) -> [CompletenessMeasurement.InternalLink] {
        hrefs.map { headProbe(href: $0, timeout: timeout) }
    }

    /// Single synchronous HEAD probe. MUST be called from a background thread
    /// (the enclosing `run(...)` contract) — it blocks on a semaphore.
    static func headProbe(href: String, timeout: TimeInterval) -> CompletenessMeasurement.InternalLink {
        guard let url = URL(string: href) else {
            return CompletenessMeasurement.InternalLink(href: href, statusCode: nil)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = timeout
        let statusBox = AnyBox()
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { _, response, _ in
            if let http = response as? HTTPURLResponse {
                statusBox.value = http.statusCode
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            return CompletenessMeasurement.InternalLink(href: href, statusCode: nil)
        }
        return CompletenessMeasurement.InternalLink(href: href, statusCode: statusBox.value as? Int)
    }

    /// Whole-run measurement failure — mirrors runner.ts's browser-exception
    /// path (structured `fail` with `assertions_passed: 0`,
    /// `assertions_failed: 0`, axes populated) so a decode/eval error surfaces
    /// as a fail the caller can distinguish from an assertion failure, rather
    /// than a fabricated per-axis pass.
    static func measurementFailure(_ axesRun: [String], _ advisory: String) -> PlaywrightResult {
        PlaywrightResult(
            resultStatus: "fail",
            axesRun: axesRun,
            assertionsPassed: 0,
            assertionsFailed: 0,
            screenshotPath: nil,
            advisory: advisory
        )
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
