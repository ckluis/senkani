import Foundation

/// V.3a — Pure-Core, SwiftUI-free value type holding the live per-pane
/// metadata the sidebar (V.3 GUI remainder) renders as chips + a hover
/// popover. Landed in `Sources/Core` (operator decision 2026-05-07) so
/// V.15a (TUI scaffold) and V.17 (provider-health-dashboard) reuse the
/// same observable model without a refactor.
///
/// `Codable` so the value round-trips through JSON for the IPC reuse the
/// later surfaces need; `Equatable` so a resolver can diff snapshots and
/// skip redundant publishes; `Sendable` so it crosses the lock-guarded
/// cache boundary without an `@unchecked` escape hatch.
///
/// Invariant (Schneier): `currentTool` / `lastReplySummary` are the only
/// hover-bound free-text fields. They are REDACTED on the write into the
/// `PaneMetadataResolver` cache (`SecretDetector.scan(...).redacted`), so a
/// `PaneMetadata` value read at hover-time can never carry an un-redacted
/// secret. The struct itself is a dumb carrier — the redaction contract
/// lives at the resolver write boundary, not here.
public struct PaneMetadata: Sendable, Codable, Equatable {

    /// One open PR reference for the pane's branch. Number + URL only —
    /// review-state surfacing is V.5/V.6 territory (parent out-of-scope).
    public struct PRRef: Sendable, Codable, Equatable {
        public let number: Int
        public let url: String

        public init(number: Int, url: String) {
            self.number = number
            self.url = url
        }
    }

    /// `localhost:<port>` the pane's shell owns, if any. Resolved by the
    /// GUI round's lsof probe; nil until that seam yields a value.
    public let port: Int?
    /// Per-pane git branch (panes can diverge from the project root in
    /// worktrees). Resolved by the GUI round's git probe; nil otherwise.
    public let branch: String?
    /// Open PR for `branch`, if the gh probe found one. nil otherwise.
    public let prRef: PRRef?
    /// Active in-flight tool name. REDACTED on the resolver write path.
    public let currentTool: String?
    /// ≤80-char last-reply summary. REDACTED on the resolver write path.
    public let lastReplySummary: String?
    /// When this snapshot was last updated. Lets the GUI debounce.
    public let lastUpdated: Date

    public init(
        port: Int? = nil,
        branch: String? = nil,
        prRef: PRRef? = nil,
        currentTool: String? = nil,
        lastReplySummary: String? = nil,
        lastUpdated: Date = Date()
    ) {
        self.port = port
        self.branch = branch
        self.prRef = prRef
        self.currentTool = currentTool
        self.lastReplySummary = lastReplySummary
        self.lastUpdated = lastUpdated
    }
}
