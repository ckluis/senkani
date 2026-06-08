import Foundation

/// V.3a — Pure-Core, SwiftUI-free cache + ingest coordinator for
/// `PaneMetadata`. Holds a `[paneId: PaneMetadata]` map behind an
/// `NSLock`. The synchronous `metadata(for:)` cache-hit read is what
/// makes the parent's <100ms p95 hover budget achievable by construction:
/// hover never blocks on a probe or a DB read, it returns the last cached
/// snapshot.
///
/// ## Schneier — redact-on-write fail-CLOSED
/// `updateAgentStatus(...)` runs BOTH `currentTool` and `lastReplySummary`
/// through `SecretDetector.scan(...).redacted` BEFORE the value lands in the
/// cache. The redaction is on the WRITE, not the read: once stored, no
/// un-redacted value exists in the map, so every hover-time read is safe by
/// construction. There is no code path that stores an un-redacted hover
/// string — a future caller cannot accidentally bypass redaction by reading
/// the cache directly.
///
/// ## Injected-closure seams (port / branch / PR)
/// Port (lsof), branch (git FSEvents), and PR (gh) ingest are the parent's
/// real-external GUI remainder. This Core type exposes them as injectable
/// closures defaulting to no-op so the GUI round wires the real probes
/// without a refactor; Core stores whatever the seam yields. The closures
/// are NOT called automatically — the GUI round drives them — but the
/// `ingestPort/Branch/PR` methods that route through them ARE here so the
/// write-merge logic (preserve other fields, bump `lastUpdated`) lives in
/// one tested place.
public final class PaneMetadataResolver: @unchecked Sendable {

    private let lock = NSLock()
    private var cache: [String: PaneMetadata] = [:]

    /// Clock seam — tests inject a fixed clock so `lastUpdated` is
    /// deterministic. Production uses the wall clock.
    private let now: () -> Date

    /// Redaction seam — defaults to the production `SecretDetector`. Tests
    /// can inject a stub to assert the write path calls it, but the default
    /// is the real fail-CLOSED scanner so the resolver "just works".
    private let redact: (String) -> String

    /// Injected port-ingest seam (lsof). Default no-op (returns nil).
    private let portProbe: (String) -> Int?
    /// Injected branch-ingest seam (git). Default no-op (returns nil).
    private let branchProbe: (String) -> String?
    /// Injected PR-ingest seam (gh). Default no-op (returns nil).
    private let prProbe: (String) -> PaneMetadata.PRRef?

    public init(
        now: @escaping () -> Date = { Date() },
        redact: @escaping (String) -> String = { SecretDetector.scan($0).redacted },
        portProbe: @escaping (String) -> Int? = { _ in nil },
        branchProbe: @escaping (String) -> String? = { _ in nil },
        prProbe: @escaping (String) -> PaneMetadata.PRRef? = { _ in nil }
    ) {
        self.now = now
        self.redact = redact
        self.portProbe = portProbe
        self.branchProbe = branchProbe
        self.prProbe = prProbe
    }

    // MARK: - Reads (synchronous cache hit — the hover path)

    /// Synchronous cache-hit read. Returns the last stored snapshot for a
    /// pane, or `nil` if no metadata has been ingested yet. This is the
    /// hover read path: it never blocks on a probe or DB.
    public func metadata(for paneId: String) -> PaneMetadata? {
        lock.lock(); defer { lock.unlock() }
        return cache[paneId]
    }

    // MARK: - Agent-status write (redact-on-write)

    /// Update `currentTool` + `lastReplySummary` for a pane. BOTH strings
    /// are redacted through `SecretDetector.scan(...).redacted` BEFORE
    /// storing (Schneier fail-CLOSED) — so no un-redacted value is ever
    /// readable at hover-time. Other fields (port/branch/prRef) are
    /// preserved from any existing snapshot; `lastUpdated` bumps.
    ///
    /// Passing `nil` for a field clears it (and is a no-op for redaction).
    public func updateAgentStatus(
        paneId: String,
        currentTool: String?,
        lastReplySummary: String?
    ) {
        let redactedTool = currentTool.map(redact)
        let redactedSummary = lastReplySummary.map(redact)
        lock.lock(); defer { lock.unlock() }
        let prior = cache[paneId]
        cache[paneId] = PaneMetadata(
            port: prior?.port,
            branch: prior?.branch,
            prRef: prior?.prRef,
            currentTool: redactedTool,
            lastReplySummary: redactedSummary,
            lastUpdated: now()
        )
    }

    // MARK: - Probe-backed ingest seams (GUI round wires the closures)

    /// Ingest the port for a pane by running the injected `portProbe`
    /// against `probeKey` (the GUI round passes the pane's shell PGID /
    /// working dir). Preserves other fields, bumps `lastUpdated`. Default
    /// probe is a no-op, so this stores `port: nil` in Core until the GUI
    /// round wires a real lsof closure.
    public func ingestPort(paneId: String, probeKey: String) {
        let value = portProbe(probeKey)
        merge(paneId: paneId) { prior in
            PaneMetadata(
                port: value,
                branch: prior?.branch,
                prRef: prior?.prRef,
                currentTool: prior?.currentTool,
                lastReplySummary: prior?.lastReplySummary,
                lastUpdated: now()
            )
        }
    }

    /// Ingest the branch for a pane via the injected `branchProbe`.
    public func ingestBranch(paneId: String, probeKey: String) {
        let value = branchProbe(probeKey)
        merge(paneId: paneId) { prior in
            PaneMetadata(
                port: prior?.port,
                branch: value,
                prRef: prior?.prRef,
                currentTool: prior?.currentTool,
                lastReplySummary: prior?.lastReplySummary,
                lastUpdated: now()
            )
        }
    }

    /// Ingest the PR ref for a pane via the injected `prProbe`.
    public func ingestPR(paneId: String, probeKey: String) {
        let value = prProbe(probeKey)
        merge(paneId: paneId) { prior in
            PaneMetadata(
                port: prior?.port,
                branch: prior?.branch,
                prRef: value,
                currentTool: prior?.currentTool,
                lastReplySummary: prior?.lastReplySummary,
                lastUpdated: now()
            )
        }
    }

    // MARK: - Internal

    private func merge(paneId: String, _ transform: (PaneMetadata?) -> PaneMetadata) {
        lock.lock(); defer { lock.unlock() }
        cache[paneId] = transform(cache[paneId])
    }
}
