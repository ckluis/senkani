import SwiftUI
import WebKit

/// Embedded web browser pane — navigate URLs, preview localhost, read docs.
/// Uses WKWebView with a URL bar, back/forward, and refresh.
struct BrowserPaneView: View {
    @Bindable var pane: PaneModel
    @State private var urlText: String = ""
    @State private var isLoading = false
    @State private var pageTitle: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // URL bar
            HStack(spacing: 6) {
                Button { webViewState?.goBack() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!(webViewState?.canGoBack ?? false))

                Button { webViewState?.goForward() } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .disabled(!(webViewState?.canGoForward ?? false))

                Button { webViewState?.reload() } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)

                TextField("URL or search...", text: $urlText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SenkaniTheme.paneBody)
                    .cornerRadius(4)
                    .onSubmit { navigateTo(urlText) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneShell)

            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            // Web content
            BrowserWebView(
                urlString: pane.previewFilePath,
                isLoading: $isLoading,
                pageTitle: $pageTitle,
                state: $webViewState
            )
        }
        .onAppear {
            if pane.previewFilePath.isEmpty {
                urlText = "https://docs.anthropic.com"
            } else {
                urlText = pane.previewFilePath
            }
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
}

/// WKWebView wrapper for the browser pane.
struct BrowserWebView: NSViewRepresentable {
    let urlString: String
    @Binding var isLoading: Bool
    @Binding var pageTitle: String
    @Binding var state: WKWebView?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        state = wv

        if let url = URL(string: urlString.isEmpty ? "https://docs.anthropic.com" : urlString) {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, pageTitle: $pageTitle)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var pageTitle: String

        init(isLoading: Binding<Bool>, pageTitle: Binding<String>) {
            _isLoading = isLoading
            _pageTitle = pageTitle
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
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
