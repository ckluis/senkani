import Foundation

/// U.2b-1a — protocol abstracting the browser runner that
/// `BrowserValidationDispatcher` invokes. Two concrete conformers ship
/// across U.2b:
///   - `PlaywrightSubprocessRunner` (U.2a-1; U.2b-1a refactor) — node
///     subprocess driving Chromium via Resources/playwright-runner/
///     runner.ts.
///   - `BrowserPaneRunner` (U.2b-1b, off-screen WKWebView) — lands behind
///     `BrowserDispatchMode.headless`. Until then the headless arm
///     returns a structured `headless_not_yet_implemented` refusal.
public protocol BrowserRunner: Sendable {
    func run(plan: [ValidationStep], targetURL: String, screenshot: Bool) throws -> PlaywrightResult
}

/// U.2b-1a — dispatch-mode selector for the browser validation surface.
/// MCP `senkani_validate_browser`'s `dispatch:` arg and the CLI
/// `senkani validate --browser --dispatch <value>` Option both normalize
/// into this enum. U.2b-2 adds a third case `.pane(PaneModel)` that
/// drives a visible pane; not in this round's scope.
///
/// Codable round-trip uses the raw string values directly so MCP/CLI
/// callers can pass `"subprocess"` / `"headless"`. Unknown strings are
/// rejected at the MCP/CLI parsing layer (not the enum itself) so the
/// caller sees a structured `invalidArguments` envelope with the
/// expected-values list.
public enum BrowserDispatchMode: String, Codable, Sendable, CaseIterable {
    case subprocess
    case headless

    /// Value written to the `runner=` field on `validation.dispatch` +
    /// `validation.fail.allow` audit-chain rows. The headless arm uses
    /// the explicit `wkwebview-headless` name so observability rows
    /// distinguish the off-screen WKWebView path from any future
    /// `pane(WKWebView)` variant.
    public var auditChainRunnerValue: String {
        switch self {
        case .subprocess: return "subprocess"
        case .headless: return "wkwebview-headless"
        }
    }
}
