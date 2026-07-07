import SwiftUI
import WebKit
import AppKit
import Core
import BrowserPane

/// Embedded web browser pane — navigate URLs, preview localhost, read docs.
/// Uses WKWebView with a URL bar, back/forward, and refresh.
///
/// When `SENKANI_BROWSER_DESIGN=on`, ⌥⇧D toggles click-to-capture
/// Design Mode on this pane (see `BrowserDesignController`).
struct BrowserPaneView: View {
    @Bindable var pane: PaneModel
    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var pageTitle: String = ""
    @State private var designController = BrowserDesignController()
    @State private var keyMonitor: Any?
    /// U.2b-2 GUI child a-2 — the pane input-lock + refusal banner are NO
    /// LONGER local `@State`. They were an orphaned mutation-island: nothing
    /// but the banner's own dismiss handler ever wrote them, so a
    /// `dispatch: .pane` run could not lock the pane or raise the banner. The
    /// visible-pane runner now writes its outcome into the process-global
    /// `PaneDispatchStateStore`, keyed by `pane_id`; this view OBSERVES that
    /// store and reads the entry for its own `pane.id`. `PaneLockStateMachine`
    /// remains the sole transition authority — the store delegates to it.
    @ObservedObject private var dispatchStore = PaneDispatchStateStore.shared

    /// The observed lock/banner state for THIS pane. Reads the store entry
    /// keyed by `pane.id`; an unseen pane reads as unlocked / no-banner.
    private var paneState: PaneDispatchStateStore.PaneState {
        dispatchStore.state(for: pane.id.uuidString)
    }

    var body: some View {
        VStack(spacing: 0) {
            // URL bar
            HStack(spacing: 6) {
                // U.2b-2 GUI child a-1 — nav gestures disabled while the
                // pane input-lock is engaged (a `dispatch: .pane` run is in
                // flight or a refusal banner is up), so the operator cannot
                // navigate the pane out from under an axis evaluation.
                Button { webViewState?.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!paneState.inputEnabled || !(webViewState?.canGoBack ?? false))

                Button { webViewState?.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!paneState.inputEnabled || !(webViewState?.canGoForward ?? false))

                Button { webViewState?.reload() } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!paneState.inputEnabled)

                TextField("URL or search...", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SenkaniTheme.paneBody)
                    .cornerRadius(4)
                    .onSubmit { navigateTo(urlText) }
                    // URL bar disabled during dispatch — the pane input-lock.
                    .disabled(!paneState.inputEnabled)

                if BrowserDesignMode.isEnabled() {
                    Image(systemName: designController.state.isActive ? "cursorarrow.rays" : "cursorarrow")
                        .font(.system(size: 10))
                        .foregroundStyle(designController.state.isActive ? Color.orange : Color.secondary)
                        .help("Design Mode (⌥⇧D) — click an element to capture")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneShell)

            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            // Web content with optional toast + refusal-banner overlays.
            ZStack(alignment: .top) {
                BrowserWebView(
                    urlString: pane.previewFilePath,
                    isLoading: $isLoading,
                    pageTitle: $pageTitle,
                    state: $webViewState,
                    onDidStartNavigation: { [paneId = pane.id.uuidString] in
                        designController.didStartNavigation(paneId: paneId)
                    },
                    onWebViewReady: { [paneId = pane.id.uuidString] webView in
                        // U.2b-2 GUI child a-1 — publish this pane's live
                        // WKWebView so `BrowserPaneRunner`'s visible-pane
                        // mode can resolve `pane_id` → this surface.
                        LivePaneRegistry.shared.register(paneId: paneId, surface: webView)
                    }
                )

                // U.2b-2 GUI child a-2 — refusal-banner overlay, rendered
                // from the OBSERVED store payload (not local state). Shown
                // ONLY when a `dispatch: .pane` run wrote a refusal into the
                // store for this pane. The banner is built from the store's
                // two Schneier-safe fields (`failingAxis` + `fixtureId`) —
                // no captured output can reach it. Dismiss routes back
                // through the store (delegates `.bannerDismissed` to the
                // machine, which unlocks the pane and clears the payload).
                if let refusal = paneState.refusal {
                    RefusalBannerView(
                        banner: RefusalBanner(
                            failingAxis: refusal.failingAxis,
                            fixtureId: refusal.fixtureId
                        ),
                        onDismiss: {
                            dispatchStore.dismissBanner(paneId: pane.id.uuidString)
                        },
                        onOpenAdvisory: {
                            RefusalBanner(
                                failingAxis: refusal.failingAxis,
                                fixtureId: refusal.fixtureId
                            ).printAdvisory()
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let toast = designController.toast {
                    Text(toast)
                        .font(.system(size: 11))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.78))
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                        .padding(.top, 10)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: designController.toast)
        }
        .onAppear {
            if pane.previewFilePath.isEmpty {
                urlText = "https://docs.anthropic.com"
            } else {
                urlText = pane.previewFilePath
            }
            installKeyMonitor()
        }
        .onDisappear {
            designController.paneClosed(paneId: pane.id.uuidString)
            // U.2b-2 GUI child a-1 — unregister this pane's surface so a
            // stale `pane_id` fail-closed-refuses (never resolves to a
            // different, still-live pane).
            LivePaneRegistry.shared.unregister(paneId: pane.id.uuidString)
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
    }

    @State private var webViewState: WKWebView?

    private func navigateTo(_ input: String) {
        var urlString = input.trimmingCharacters(in: .whitespaces)
        if !urlString.contains("://") {
            if urlString.contains(".") && !urlString.contains(" ") {
                urlString = "https://" + urlString
            } else {
                urlString = "https://www.google.com/search?q=" + (urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlString)
            }
        }
        pane.previewFilePath = urlString
        if let url = URL(string: urlString) {
            webViewState?.load(URLRequest(url: url))
        }
    }

    /// Install the ⌥⇧D monitor. The monitor is global-to-app, so we guard
    /// on "is this pane's WKWebView the current first responder" before
    /// handling.
    private func installKeyMonitor() {
        guard BrowserDesignMode.isEnabled() else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let needed: NSEvent.ModifierFlags = [.option, .shift]
            let isDesignChord = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == needed
                && (event.charactersIgnoringModifiers?.lowercased() == "d")
            guard isDesignChord else { return event }
            guard let webView = webViewState, isDescendantFirstResponder(webView) else { return event }
            designController.toggle(
                paneId: pane.id.uuidString,
                webView: webView,
                projectRoot: pane.workingDirectory.isEmpty ? nil : pane.workingDirectory
            )
            return nil  // consumed
        }
        keyMonitor = monitor
    }

    private func isDescendantFirstResponder(_ view: NSView) -> Bool {
        guard let window = view.window, let fr = window.firstResponder else { return false }
        if fr === view { return true }
        if let frView = fr as? NSView, frView.isDescendant(of: view) { return true }
        return false
    }
}

/// WKWebView wrapper for the browser pane.
struct BrowserWebView: NSViewRepresentable {
    let urlString: String
    @Binding var isLoading: Bool
    @Binding var pageTitle: String
    @Binding var state: WKWebView?
    var onDidStartNavigation: (() -> Void)? = nil
    /// U.2b-2 GUI child a-1 — called once the live WKWebView exists so the
    /// pane can publish it into `LivePaneRegistry` for `.pane` dispatch.
    var onWebViewReady: ((WKWebView) -> Void)? = nil

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        state = wv
        onWebViewReady?(wv)

        if let url = URL(string: urlString.isEmpty ? "https://docs.anthropic.com" : urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, pageTitle: $pageTitle, onDidStartNavigation: onDidStartNavigation)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var pageTitle: String
        let onDidStartNavigation: (() -> Void)?

        init(isLoading: Binding<Bool>, pageTitle: Binding<String>, onDidStartNavigation: (() -> Void)?) {
            _isLoading = isLoading
            _pageTitle = pageTitle
            self.onDidStartNavigation = onDidStartNavigation
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            onDidStartNavigation?()
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
            pageTitle = webView.title ?? ""
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isLoading = false
        }
    }
}
