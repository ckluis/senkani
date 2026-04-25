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

    public init(
        database: SessionDatabase = .shared,
        registry: ValidatorRegistry = .shared,
        configLoader: @escaping @Sendable (String) -> AutoValidateConfig = { AutoValidateConfig.load(projectRoot: $0) }
    ) {
        self.database = database
        self.registry = registry
        self.configLoader = configLoader
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
    public func drainForTesting(timeoutMs: Int = 5_000) async {
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
        db.recordEvent(type: "auto_validate.started", projectRoot: item.projectRoot)

        // Run validation on a background thread (not the actor)
        Task.detached(priority: .utility) { [weak self] in
            let attempts = AutoValidateWorker.validateAttempts(
                path: item.path,
                projectRoot: item.projectRoot,
                categories: categories,
                timeoutMs: timeoutMs,
                registry: registry
            )

            // Store results in DB
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
