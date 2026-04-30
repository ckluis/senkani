import Foundation

/// V.12b — `HookRouter` denial → diff-annotation pipeline.
///
/// `HookAnnotation` is the deny-side carrier; UI layers convert it
/// into `DiffAnnotation` once a hunk in the active diff matches the
/// denied tool's `filePath`. This separation keeps Core out of
/// SwiftUI: the feed runs on the hook queue, the pane subscribes
/// from the main actor.
///
/// Severity uses the V.12a frozen vocabulary. Denials that actually
/// block work (ConfirmationGate, budget gate) are `must-fix`; the
/// router uses `suggestion`/`question`/`nit` for advisories that
/// merely redirect tool calls.
public struct HookAnnotation: Sendable, Equatable {
    public let id: UUID
    public let severity: DiffAnnotationSeverity
    /// Free-text body. Mirrors the deny `permissionDecisionReason`
    /// so the operator sees the same wording in the diff sidebar
    /// that the agent saw in its tool response.
    public let body: String
    /// Tool that triggered the denial (`Edit`, `Write`, `Bash`, …).
    public let toolName: String
    /// File path the tool was about to touch, if known. Pane
    /// matches this against `leftPath`/`rightPath` to decide whether
    /// the annotation belongs in the currently-shown diff.
    public let filePath: String?
    public let sessionId: String?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        severity: DiffAnnotationSeverity,
        body: String,
        toolName: String,
        filePath: String? = nil,
        sessionId: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.severity = severity
        self.body = body
        self.toolName = toolName
        self.filePath = filePath
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Outcome returned by `HookAnnotationFeed.record(_:)`. Suppression
/// is observable to callers so HookRouter can write a counter for
/// the dashboard, but it does NOT change the deny response — the
/// agent still sees the deny.
public enum HookAnnotationOutcome: Sendable, Equatable {
    case admitted
    case suppressed
}

/// Persistence sink row for `annotation_rate_cap_log`. Written when
/// a window with at least one suppressed must-fix rolls over.
public struct AnnotationRateCapLogRow: Sendable, Equatable {
    public let windowStart: Date
    public let windowEnd: Date
    public let severity: String
    public let suppressedCount: Int
    public let threshold: Int

    public init(
        windowStart: Date,
        windowEnd: Date,
        severity: String,
        suppressedCount: Int,
        threshold: Int
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.severity = severity
        self.suppressedCount = suppressedCount
        self.threshold = threshold
    }
}

/// Process-singleton fan-out + rate cap for `HookAnnotation` records.
///
/// HookRouter writes to `.shared`; subscribers (DiffViewerPane in
/// SenkaniApp, tests) attach via `subscribe`. The rate cap counts
/// `must-fix` admissions per `windowSeconds`. When the count for a
/// window hits `mustFixThreshold`, further must-fix annotations are
/// `suppressed` until the window rolls. The roll writes a
/// `AnnotationRateCapLogRow` to the persistence sink with the final
/// suppressed count.
///
/// Subscribers are invoked WITHOUT the lock held — handlers must
/// not block, but they may call back into the feed (for tests).
public final class HookAnnotationFeed: @unchecked Sendable {
    public static let shared = HookAnnotationFeed()

    public let windowSeconds: TimeInterval
    public let mustFixThreshold: Int

    private let lock = NSLock()
    private var subscribers: [(HookAnnotation) -> Void] = []
    /// Start of the current rate-cap window. `.distantPast` until
    /// the first `record(_:)` call so the first event opens the
    /// window cleanly.
    private var windowStart: Date = .distantPast
    private var mustFixAdmittedInWindow: Int = 0
    private var mustFixSuppressedInWindow: Int = 0

    /// Persistence sink for rate-cap log rows. Test seam — production
    /// wires to `SessionDatabase.shared.recordAnnotationRateCap(...)`
    /// via the default closure below.
    nonisolated(unsafe) public var rateCapSink: (AnnotationRateCapLogRow) -> Void

    public init(
        windowSeconds: TimeInterval = 60,
        mustFixThreshold: Int = 5,
        rateCapSink: @escaping (AnnotationRateCapLogRow) -> Void = { row in
            SessionDatabase.shared.recordAnnotationRateCap(row)
        }
    ) {
        self.windowSeconds = windowSeconds
        self.mustFixThreshold = mustFixThreshold
        self.rateCapSink = rateCapSink
    }

    /// Append a subscriber. Subscribers cannot be removed in V.12b —
    /// the SenkaniApp pane subscribes once at app launch and lives
    /// for the process lifetime. Tests should call `reset()` instead.
    public func subscribe(_ handler: @escaping (HookAnnotation) -> Void) {
        lock.lock()
        subscribers.append(handler)
        lock.unlock()
    }

    /// Record one annotation. Returns `.admitted` (subscribers
    /// notified) or `.suppressed` (silently dropped because the
    /// must-fix rate cap is closed for this window).
    @discardableResult
    public func record(_ annotation: HookAnnotation, now: Date = Date()) -> HookAnnotationOutcome {
        var rolloverRow: AnnotationRateCapLogRow?
        var subsSnapshot: [(HookAnnotation) -> Void] = []
        let outcome: HookAnnotationOutcome

        lock.lock()
        if windowStart == .distantPast || now.timeIntervalSince(windowStart) >= windowSeconds {
            if mustFixSuppressedInWindow > 0 {
                rolloverRow = AnnotationRateCapLogRow(
                    windowStart: windowStart,
                    windowEnd: windowStart.addingTimeInterval(windowSeconds),
                    severity: DiffAnnotationSeverity.mustFix.rawValue,
                    suppressedCount: mustFixSuppressedInWindow,
                    threshold: mustFixThreshold
                )
            }
            windowStart = now
            mustFixAdmittedInWindow = 0
            mustFixSuppressedInWindow = 0
        }

        if annotation.severity == .mustFix {
            if mustFixAdmittedInWindow >= mustFixThreshold {
                mustFixSuppressedInWindow += 1
                outcome = .suppressed
            } else {
                mustFixAdmittedInWindow += 1
                outcome = .admitted
            }
        } else {
            outcome = .admitted
        }

        if outcome == .admitted {
            subsSnapshot = subscribers
        }
        lock.unlock()

        if let row = rolloverRow {
            rateCapSink(row)
        }
        for sub in subsSnapshot {
            sub(annotation)
        }
        return outcome
    }

    /// Test-only reset. Drops subscribers and rate-cap state. Does
    /// NOT flush a pending rollover — tests assert the rollover
    /// path explicitly by advancing the clock through `record(_:)`.
    public func reset() {
        lock.lock()
        subscribers.removeAll()
        windowStart = .distantPast
        mustFixAdmittedInWindow = 0
        mustFixSuppressedInWindow = 0
        lock.unlock()
    }
}
