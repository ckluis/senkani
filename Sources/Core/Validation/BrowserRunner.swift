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
/// into this enum.
///
/// U.2b-2 child (a) adds the third case `.pane`, which targets a
/// visible `BrowserPane`. Until child (b) wires the actual pane
/// execution (the GUI/Cowork half), `.pane` resolves to a structured
/// `validation_browser_pane_not_yet_wired` refusal in
/// `BrowserValidationDispatcher` — a correctly-shaped audit row + fail
/// Response, so the three-value parity and mixed-runner chain-integrity
/// tests hold byte-for-byte regardless of which arm runs. The
/// `pane_id` selector rides `BrowserValidationDispatcher.Request.paneId`
/// (default-safe: `nil` resolves to the most-recently-focused pane once
/// child (b) lands the registry).
///
/// Codable round-trip uses the raw string values directly so MCP/CLI
/// callers can pass `"subprocess"` / `"headless"` / `"pane"`. Unknown
/// strings are rejected at the MCP/CLI parsing layer (not the enum
/// itself) so the caller sees a structured `invalidArguments` envelope
/// with the expected-values list.
public enum BrowserDispatchMode: String, Codable, Sendable, CaseIterable {
    case subprocess
    case headless
    case pane

    /// Value written to the `runner=` field on `validation.dispatch` +
    /// `validation.fail.allow` audit-chain rows. The headless arm uses
    /// the explicit `wkwebview-headless` name so observability rows
    /// distinguish the off-screen WKWebView path; the pane arm uses
    /// `wkwebview-pane` so the visible-pane path is distinguishable from
    /// both the off-screen headless and the node-subprocess paths. These
    /// three values are the closed set the audit-chain `runner` field
    /// carries (no row schema change — same `runner=<value>` column).
    public var auditChainRunnerValue: String {
        switch self {
        case .subprocess: return "subprocess"
        case .headless: return "wkwebview-headless"
        case .pane: return "wkwebview-pane"
        }
    }
}
