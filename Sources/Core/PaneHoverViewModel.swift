import Foundation

/// V.3c — Pure-Core, SwiftUI-free assembly of the per-pane hover popover's
/// display fields from a `PaneMetadata` snapshot. This is the DATA path the
/// parent's `<100ms p95` hover popover depends on: the GUI child (`phase-v3d`)
/// renders these pre-computed strings, so the render timer measures view
/// construction only, not string/label assembly.
///
/// It exists here (Core) so the assembly cost — the part that CAN be measured
/// headlessly — is exercised by the coordinator's latency stand-in test. The
/// actual SwiftUI render timing stays in `phase-v3d`.
///
/// All fields are `nil` when the underlying metadata field is absent, so the
/// GUI can conditionally render each chip without re-deriving presence.
public struct PaneHoverViewModel: Sendable, Equatable {
    /// `localhost:<port>`, or nil when no port chip.
    public let portLabel: String?
    /// Branch name, or nil.
    public let branchLabel: String?
    /// `#<number>` PR label, or nil.
    public let prLabel: String?
    /// Open-PR URL, or nil (the GUI makes the `#N` chip a link).
    public let prURL: String?
    /// Active tool name (already redacted on the resolver write path).
    public let currentTool: String?
    /// Last-reply summary (already redacted on the resolver write path).
    public let lastReplySummary: String?
    /// Snapshot age source — the GUI debounces / greys stale chips off this.
    public let lastUpdated: Date

    public init(metadata: PaneMetadata) {
        self.portLabel = metadata.port.map { "localhost:\($0)" }
        self.branchLabel = metadata.branch
        self.prLabel = metadata.prRef.map { "#\($0.number)" }
        self.prURL = metadata.prRef?.url
        self.currentTool = metadata.currentTool
        self.lastReplySummary = metadata.lastReplySummary
        self.lastUpdated = metadata.lastUpdated
    }

    /// Build the hover view-model straight from a resolver cache read. Returns
    /// nil when the pane has no ingested metadata yet. This is the exact call
    /// the GUI hover handler makes — a synchronous cache hit plus struct
    /// assembly, no probe, no I/O.
    public static func build(from resolver: PaneMetadataResolver, paneId: String) -> PaneHoverViewModel? {
        guard let metadata = resolver.metadata(for: paneId) else { return nil }
        return PaneHoverViewModel(metadata: metadata)
    }
}
