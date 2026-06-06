import Foundation

/// Process-global debounced auto-validation queue.
/// Enqueues validation work from PostToolUse hooks, debounces rapid edits,
/// enforces maxConcurrent, and stores results in SessionDatabase.
public actor AutoValidateQueue {
    public static let shared = AutoValidateQueue()

    private var pending: [String: PendingValidation] = [:]
    private var running: Int = 0
    private var config: AutoValidateConfig = .default
    private let database: SessionDatabase
    private let registry: ValidatorRegistry
    private let configLoader: @Sendable (String) -> AutoValidateConfig
    /// U.9b-1 — loads the default-OFF `WorkBusConfig.dualWrite` flag.
    /// Default reads `~/.senkani/work-bus.json` (missing ⇒ dualWrite=false),
    /// so production is byte-identical to U.9a unless an operator opts in
    /// per project root. Tests inject a loader to force the flag on/off.
    private let workBusConfigLoader: @Sendable () -> WorkBusConfig

    public init(
        database: SessionDatabase = .shared,
        registry: ValidatorRegistry = .shared,
        configLoader: @escaping @Sendable (String) -> AutoValidateConfig = { AutoValidateConfig.load(projectRoot: $0) },
        workBusConfigLoader: @escaping @Sendable () -> WorkBusConfig = { (try? WorkBusConfigStore.load()) ?? WorkBusConfig() }
    ) {
        self.database = database
        self.registry = registry
        self.configLoader = configLoader
        self.workBusConfigLoader = workBusConfigLoader
    }

    struct PendingValidation {
        let path: String
        let sessionId: String
        let projectRoot: String
        let enqueuedAt: Date
        var debounceTask: Task<Void, Never>?
    }

    // MARK: - Public API

    /// Enqueue a file for validation. Non-blocking, <1ms.
    /// Debounces rapid edits on the same file within the same session.
    public func enqueue(path: String, sessionId: String, projectRoot: String) {
        // Reload config if needed
        config = configLoader(projectRoot)
        guard config.enabled else {
            record("auto_validate.skipped_disabled", projectRoot: projectRoot)
            return
        }

        // Check exclude paths
        let relativePath = path.hasPrefix(projectRoot)
            ? String(path.dropFirst(projectRoot.count + 1))
            : path
        if config.isExcluded(relativePath: relativePath) {
            record("auto_validate.skipped_excluded", projectRoot: projectRoot)
            return
        }

        // Check if any validators exist for this extension
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else {
            record("auto_validate.skipped_unsupported_extension", projectRoot: projectRoot)
            return
        }
        let validators = registry.validatorsFor(extension: ext)
        guard !validators.isEmpty else {
            record("auto_validate.skipped_no_validator", projectRoot: projectRoot)
            return
        }
        let categoryFiltered = validators.filter { config.categories.contains($0.category) }
        guard !categoryFiltered.isEmpty else {
            record("auto_validate.skipped_category_filtered", projectRoot: projectRoot)
            return
        }

        // Debounce: cancel previous task for this key, create new one
        let key = "\(sessionId):\(path)"
        if pending[key] != nil {
            pending[key]?.debounceTask?.cancel()
            record("auto_validate.debounced", projectRoot: projectRoot)
        }

        let debounceMs = config.debounceMs
        let task = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled else { return }
            await self?.startValidation(key: key)
        }

        pending[key] = PendingValidation(
            path: path,
            sessionId: sessionId,
            projectRoot: projectRoot,
            enqueuedAt: Date(),
            debounceTask: task
        )
        record("auto_validate.enqueued", projectRoot: projectRoot)
    }

    /// Update configuration (e.g., when project config changes).
    public func updateConfig(_ newConfig: AutoValidateConfig) {
        config = newConfig
    }

    /// Current count of running validations (for testing).
    public var runningCount: Int { running }

    /// Test/support seam: waits until debounced pending work and detached
    /// validation tasks have drained, then flushes queued DB writes.
    ///
    /// Default `timeoutMs` of 15 s absorbs cooperative-pool starvation
    /// under the Swift Testing parallel runner. The pipeline crosses the
    /// cooperative pool three times (debounce `Task.sleep`, actor-hop into
    /// `startValidation`, actor-hop back from `validationCompleted`) plus
    /// a `Task.detached(priority: .utility)` whose body blocks on
    /// `Process.run` + `waitUntilExit`. Under full-suite parallel load
    /// the detached `.utility` task can be deprioritized for several
    /// seconds; the original 5 s budget lost the dice roll often enough
    /// to flake (see `autovalidatequeue-clean-validation-flake-2026-05-04`).
    /// The polling loop returns immediately on `pending.isEmpty && running == 0`,
    /// so green-path latency is unchanged — only the slow path uses the
    /// wider window.
    public func drainForTesting(timeoutMs: Int = 15_000) async {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        while Date() < deadline {
            if pending.isEmpty && running == 0 {
                database.flushWrites()
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
        database.flushWrites()
    }

    // MARK: - Internal

    private func startValidation(key: String) {
        guard let item = pending.removeValue(forKey: key) else { return }

        // Enforce maxConcurrent
        guard running < config.maxConcurrent else {
            // Re-queue for pickup when a slot opens
            pending[key] = item
            record("auto_validate.deferred_capacity", projectRoot: item.projectRoot)
            return
        }

        running += 1
        let categories = config.categories
        let timeoutMs = config.timeoutMs
        let db = database
        let registry = self.registry
        // U.9b-1 — read the default-OFF dual-write flag ONCE per
        // validation so the off-path adds zero work and the on-path is
        // deterministic for one item. NOT re-read inside the loop.
        let dualWrite = workBusConfigLoader().dualWrite
        db.recordEvent(type: "auto_validate.started", projectRoot: item.projectRoot)

        // Run validation on a background thread (not the actor).
        //
        // U.9b-1 (Carmack, no-flake): the dual-write bus leg runs
        // SYNCHRONOUSLY inside THIS already-off-actor detached worker —
        // it does NOT spawn a SECOND `Task.detached(.utility)`. That is
        // the load-bearing no-flake guarantee: we reuse the existing
        // worker's background thread for the bus enqueue + parity
        // counters instead of adding another cooperative-pool hop (the
        // R7/R8 starvation pattern). When `dualWrite == false` this block
        // is never entered and the path is byte-identical to U.9a.
        Task.detached(priority: .utility) { [weak self] in
            let attempts = AutoValidateWorker.validateAttempts(
                path: item.path,
                projectRoot: item.projectRoot,
                categories: categories,
                timeoutMs: timeoutMs,
                registry: registry
            )

            // Store results in DB (the in-process leg). The leg is
            // considered delivered when the validator produced attempts
            // and they were handed to the store (a no-attempt run is a
            // skip, not a leg failure).
            let inProcessLegOK = !attempts.isEmpty
            for attempt in attempts {
                db.insertValidationResult(
                    sessionId: item.sessionId,
                    filePath: attempt.path,
                    validatorName: attempt.validatorName,
                    category: attempt.category,
                    exitCode: attempt.exitCode,
                    rawOutput: attempt.rawOutput,
                    advisory: attempt.advisory,
                    durationMs: attempt.durationMs,
                    outcome: attempt.outcome.rawValue,
                    reason: attempt.reason
                )
                switch attempt.outcome {
                case .clean:
                    db.recordEvent(type: "auto_validate.clean", projectRoot: item.projectRoot)
                case .advisory:
                    db.recordEvent(type: "auto_validate.findings", projectRoot: item.projectRoot)
                    db.recordEvent(type: "auto_validate.advisory_created", projectRoot: item.projectRoot)
                case .dropped:
                    db.recordEvent(type: "auto_validate.dropped", projectRoot: item.projectRoot)
                    if attempt.reason == "timeout" {
                        db.recordEvent(type: "auto_validate.timeout", projectRoot: item.projectRoot)
                    } else {
                        db.recordEvent(type: "auto_validate.error", projectRoot: item.projectRoot)
                    }
                }
            }

            // Also record as a token_event for Agent Timeline visibility
            let advisoryAttempts = attempts.filter { $0.outcome == .advisory }
            if !advisoryAttempts.isEmpty {
                db.recordTokenEvent(
                    sessionId: item.sessionId,
                    paneId: nil,
                    projectRoot: item.projectRoot,
                    source: "auto_validate",
                    toolName: "validate",
                    model: nil,
                    inputTokens: 0,
                    outputTokens: 0,
                    savedTokens: 0,
                    costCents: 0,
                    feature: "auto_validate",
                    command: (item.path as NSString).lastPathComponent
                )
            }

            // U.9b-1 — dual-write bus leg (default-OFF). Only runs when an
            // operator opted in via `WorkBusConfig.dualWrite`. Reuses THIS
            // detached worker's thread — no second cooperative-pool hop.
            // When off, this is a no-op and the path is byte-identical to
            // U.9a (zero bus rows, zero parity counters).
            if dualWrite && inProcessLegOK {
                AutoValidateDualWrite.run(
                    db: db,
                    sessionId: item.sessionId,
                    path: item.path,
                    projectRoot: item.projectRoot,
                    attempts: attempts,
                    inProcessLegOK: inProcessLegOK
                )
            }

            await self?.validationCompleted()
        }
    }

    private func validationCompleted() {
        running -= 1

        // Pick up any pending work that was queued while at capacity
        if running < config.maxConcurrent, let nextKey = pending.keys.first {
            startValidation(key: nextKey)
        }
    }

    private func record(_ type: String, projectRoot: String) {
        database.recordEvent(type: type, projectRoot: projectRoot)
    }
}
