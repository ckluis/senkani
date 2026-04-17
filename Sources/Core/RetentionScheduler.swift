import Foundation

/// Retention policy knobs. Defaults match the historical in-code values; users tighten
/// via `~/.senkani/config.json` → `"retention": { ... }`.
public struct RetentionConfig: Sendable, Codable, Equatable {
    public let tokenEventsDays: Int
    public let sandboxResultsHours: Int
    public let validationResultsHours: Int
    /// How often the scheduler fires. 60 minutes by default.
    public let tickIntervalSeconds: Int

    public init(
        tokenEventsDays: Int = 90,
        sandboxResultsHours: Int = 24,
        validationResultsHours: Int = 24,
        tickIntervalSeconds: Int = 3600
    ) {
        self.tokenEventsDays = tokenEventsDays
        self.sandboxResultsHours = sandboxResultsHours
        self.validationResultsHours = validationResultsHours
        self.tickIntervalSeconds = tickIntervalSeconds
    }

    /// Load from `<projectRoot>/.senkani/config.json`, falling back to defaults.
    public static func load(projectRoot: String?) -> RetentionConfig {
        guard let root = projectRoot else { return .init() }
        let path = root + "/.senkani/config.json"
        guard let data = FileManager.default.contents(atPath: path) else { return .init() }

        struct Outer: Codable { let retention: Inner? }
        struct Inner: Codable {
            let tokenEventsDays: Int?
            let sandboxResultsHours: Int?
            let validationResultsHours: Int?
            let tickIntervalSeconds: Int?
            private enum CodingKeys: String, CodingKey {
                case tokenEventsDays = "token_events_days"
                case sandboxResultsHours = "sandbox_results_hours"
                case validationResultsHours = "validation_results_hours"
                case tickIntervalSeconds = "tick_interval_seconds"
            }
        }
        guard let outer = try? JSONDecoder().decode(Outer.self, from: data),
              let r = outer.retention else { return .init() }
        return RetentionConfig(
            tokenEventsDays: r.tokenEventsDays ?? 90,
            sandboxResultsHours: r.sandboxResultsHours ?? 24,
            validationResultsHours: r.validationResultsHours ?? 24,
            tickIntervalSeconds: r.tickIntervalSeconds ?? 3600
        )
    }
}

/// Background scheduler that prunes old rows from SessionDatabase on a regular tick.
/// Prior to this, the retention functions existed but nothing invoked them on a
/// schedule — DB grew unbounded for long-running installs.
///
/// Thread-safety: `start()` and `stop()` are idempotent and guarded by an internal
/// NSLock. All pruning work dispatches through `SessionDatabase.queue` (the internal
/// DB queue) so this class itself holds no DB state.
public final class RetentionScheduler: @unchecked Sendable {
    public static let shared = RetentionScheduler()

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.senkani.retention", qos: .background)

    /// Optional callback fired after every tick completes. Intended for tests and
    /// structured-log integration. Fires on the scheduler's background queue.
    public var onTick: (@Sendable (_ report: TickReport) -> Void)?

    public struct TickReport: Sendable {
        public let tokenEventsDays: Int
        public let sandboxResultsHours: Int
        public let validationResultsHours: Int
        public let timestamp: Date
    }

    public init() {}

    /// Start periodic pruning. First tick fires immediately (non-blocking) to avoid
    /// carrying over debt from a previously-closed session.
    public func start(config: RetentionConfig = .init()) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(config.tickIntervalSeconds))
        t.setEventHandler { [weak self] in
            self?.tick(config: config)
        }
        timer = t
        t.resume()
    }

    /// Stop the scheduler. Idempotent.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }

    /// Force a tick synchronously — primarily for tests. Uses the given config.
    public func tickNow(config: RetentionConfig = .init()) {
        tick(config: config)
    }

    private func tick(config: RetentionConfig) {
        let tokenPruned = SessionDatabase.shared.pruneTokenEvents(
            olderThanDays: config.tokenEventsDays
        )
        let sandboxPruned = SessionDatabase.shared.pruneSandboxedResults(
            olderThan: TimeInterval(config.sandboxResultsHours) * 3600
        )
        let validationPruned = SessionDatabase.shared.pruneValidationResults(
            olderThanHours: config.validationResultsHours
        )

        Logger.log("retention.tick", fields: [
            "token_events_days": .int(config.tokenEventsDays),
            "sandbox_results_hours": .int(config.sandboxResultsHours),
            "validation_results_hours": .int(config.validationResultsHours),
            "token_events_pruned": .int(tokenPruned),
            "sandbox_results_pruned": .int(sandboxPruned),
            "validation_results_pruned": .int(validationPruned)
        ])

        // Observability: increment counters by the number of rows actually
        // pruned per table. Zero-delta calls are no-ops so quiet ticks
        // don't pollute the counter table.
        SessionDatabase.shared.recordEvent(
            type: "retention.pruned.token_events", delta: tokenPruned)
        SessionDatabase.shared.recordEvent(
            type: "retention.pruned.sandboxed_results", delta: sandboxPruned)
        SessionDatabase.shared.recordEvent(
            type: "retention.pruned.validation_results", delta: validationPruned)

        let report = TickReport(
            tokenEventsDays: config.tokenEventsDays,
            sandboxResultsHours: config.sandboxResultsHours,
            validationResultsHours: config.validationResultsHours,
            timestamp: Date()
        )
        onTick?(report)
    }
}
