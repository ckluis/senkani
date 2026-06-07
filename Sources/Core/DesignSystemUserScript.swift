#if canImport(WebKit)
import Foundation
import WebKit

/// V.10b — builds the `WKUserScript` array `HTMLPreviewView` registers
/// on its WKWebView for a given render mode.
///
/// `.original` returns `[]` (no scripts; WebView renders the source
/// as authored). `.designSystem` returns one script whose source
/// inserts a `<style>...</style>` block at document-end carrying the
/// generated stylesheet. The `data-senkani-design-system="1"`
/// attribute marks the injected block for debugging + test assertions.
public enum DesignSystemUserScript {

    public static func userScripts(for mode: HTMLPreviewMode,
                                   css: String) -> [WKUserScript] {
        switch mode {
        case .original:
            return []
        case .designSystem:
            let script = WKUserScript(
                source: makeSource(css: css),
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: false
            )
            return [script]
        }
    }

    /// Internal JS source builder — exposed for unit tests asserting
    /// the source string shape.
    public static func makeSource(css: String) -> String {
        // Escape CSS so it can be placed inside a single-quoted JS
        // string and inside a `<style>...</style>` block.
        let cssForJS = css
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "</style>", with: "<\\/style>")

        return """
        (function() {
          var html = '<style data-senkani-design-system="1">' + '\(cssForJS)' + '</style>';
          if (document.head) {
            document.head.insertAdjacentHTML('beforeend', html);
          } else {
            document.documentElement.insertAdjacentHTML('beforeend', html);
          }
        })();
        """
    }
}
#endif
