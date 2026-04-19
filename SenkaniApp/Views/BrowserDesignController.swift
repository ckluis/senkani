import SwiftUI
import WebKit
import AppKit
import Core

/// SenkaniApp-side integration for Browser Design Mode. Owns the
/// WKUserScript + WKScriptMessageHandler lifecycle and the toast state.
/// Pure logic lives in `Core.BrowserDesignMode`.
@MainActor
@Observable
final class BrowserDesignController: NSObject {

    // MARK: - State

    private(set) var state = BrowserDesignMode.State()

    /// User-visible toast message. Non-nil for ~2s after a capture or
    /// rejection event.
    private(set) var toast: String?

    /// Dev-visible hook so tests / SwiftUI overlays can observe. Fires
    /// on every message-handler receive (including rejections).
    private(set) var lastOutcome: BrowserDesignMode.Outcome?

    /// The last pane id we were active on — retained so navigation /
    /// dealloc teardown can find the webview again.
    private weak var boundWebView: WKWebView?
    private var messageHandler: _BridgeHandler?

    private let messageHandlerName = "senkaniDesign"
    private let userScriptTag = "senkani-design"

    // MARK: - Public API

    /// Flip ⌥⇧D: install script if off, tear down if on. Env-gate is
    /// checked — with the var unset, this is a no-op.
    func toggle(paneId: String, webView: WKWebView, projectRoot: String?) {
        guard BrowserDesignMode.isEnabled() else { return }

        if state.isActive {
            teardown()
            return
        }
        enter(paneId: paneId, webView: webView, projectRoot: projectRoot)
    }

    /// Called by BrowserPaneView when the user navigates the webview.
    /// Matches the mode-lifecycle acceptance: "Navigation exits and
    /// discards the injected user script (no leak-across-navigation)."
    func didStartNavigation(paneId: String) {
        state.navigated(paneId: paneId)
        if !state.isActive { teardown(tearDownScripts: true) }
    }

    /// Called by BrowserPaneView on disappear.
    func paneClosed(paneId: String) {
        state.paneClosed(paneId: paneId)
        if !state.isActive { teardown(tearDownScripts: true) }
    }

    // MARK: - Private

    private func enter(paneId: String, webView: WKWebView, projectRoot: String?) {
        let controller = webView.configuration.userContentController
        let handler = _BridgeHandler(parent: self)
        controller.add(handler, name: messageHandlerName)
        let script = WKUserScript(
            source: BrowserDesignMode.injectedJSSource,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        controller.addUserScript(script)

        messageHandler = handler
        boundWebView = webView
        state.enter(paneId: paneId, featureEnabled: true)
        setToast("Design Mode on — click an element to capture.")
        Counters.record(.entered, projectRoot: projectRoot)
        self.projectRoot = projectRoot
    }

    private func teardown(tearDownScripts: Bool = true) {
        if tearDownScripts, let webView = boundWebView {
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.removeScriptMessageHandler(forName: messageHandlerName)
        }
        messageHandler = nil
        boundWebView = nil
        state.exit()
        setToast("Design Mode off.")
    }

    private var projectRoot: String?

    fileprivate func receive(_ body: Any) {
        guard let dict = body as? [String: Any] else { return }
        let kind = dict["kind"] as? String ?? ""
        if kind == "exit" {
            teardown()
            return
        }
        guard kind == "capture" else { return }

        let payload = BrowserDesignMode.CapturePayload(
            tag: (dict["tag"] as? String) ?? "unknown",
            id: dict["id"] as? String,
            idIsUnique: (dict["idIsUnique"] as? Bool) ?? false,
            classes: (dict["classes"] as? [String]) ?? [],
            classSetIsUnique: (dict["classSetIsUnique"] as? Bool) ?? false,
            innerText: (dict["innerText"] as? String) ?? "",
            isShadow: (dict["isShadow"] as? Bool) ?? false,
            isCrossOriginIframe: (dict["isCrossOriginIframe"] as? Bool) ?? false
        )

        let outcome = BrowserDesignMode.process(payload: payload)
        lastOutcome = outcome

        switch outcome {
        case .captured(let element):
            let md = BrowserDesignMode.formatMarkdown(element)
            writeClipboard(md)
            let label = element.selector ?? "\(element.tag)"
            setToast("Captured \(label) — copied to clipboard.")
            Counters.record(.captured, projectRoot: projectRoot)
        case .rejected(let reason, let counter):
            setToast(reason)
            Counters.record(counter, projectRoot: projectRoot)
        }
    }

    private func writeClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private func setToast(_ message: String) {
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    // MARK: - Counters plumbing

    enum Counters {
        static func record(_ counter: BrowserDesignMode.Counter, projectRoot: String?) {
            SessionDatabase.shared.recordEvent(type: counter.rawValue, projectRoot: projectRoot)
        }
    }
}

/// Separate NSObject to avoid the WKScriptMessageHandler retain cycle on
/// the @Observable controller. Message handlers are retained by
/// `WKUserContentController` which would retain the controller back.
@MainActor
private final class _BridgeHandler: NSObject, WKScriptMessageHandler {
    weak var parent: BrowserDesignController?

    init(parent: BrowserDesignController) {
        self.parent = parent
        super.init()
    }

    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let body = message.body
        Task { @MainActor [weak self] in
            self?.parent?.receive(body)
        }
    }
}
