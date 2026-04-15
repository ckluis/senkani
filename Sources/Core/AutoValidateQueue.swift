import Foundation

/// Process-global debounced auto-validation queue.
/// Enqueues validation work from PostToolUse hooks, debounces rapid edits,
/// enforces maxConcurrent, and stores results in SessionDatabase.
public actor AutoValidateQueue {
    public static let shared = AutoValidateQueue()

    private var pending: [String: PendingValidation] = [:]
    private var running: Int = 0
    private var config: AutoValidateConfig = .default

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
        config = AutoValidateConfig.load(projectRoot: projectRoot)
        guard config.enabled else { return }

        // Check exclude paths
        let relativePath = path.hasPrefix(projectRoot)
            ? String(path.dropFirst(projectRoot.count + 1))
            : path
        if config.isExcluded(relativePath: relativePath) { return }

        // Check if any validators exist for this extension
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return }
        let validators = ValidatorRegistry.shared.validatorsFor(extension: ext)
        let categoryFiltered = validators.filter { config.categories.contains($0.category) }
        guard !categoryFiltered.isEmpty else { return }

        // Debounce: cancel previous task for this key, create new one
        let key = "\(sessionId):\(path)"
        pending[key]?.debounceTask?.cancel()

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
    }

    /// Update configuration (e.g., when project config changes).
    public func updateConfig(_ newConfig: AutoValidateConfig) {
        config = newConfig
    }

    /// Current count of running validations (for testing).
    public var runningCount: Int { running }

    // MARK: - Internal

    private func startValidation(key: String) {
        guard let item = pending.removeValue(forKey: key) else { return }

        // Enforce maxConcurrent
        guard running < config.maxConcurrent else {
            // Re-queue for pickup when a slot opens
            pending[key] = item
            return
        }

        running += 1
        let categories = config.categories
        let timeoutMs = config.timeoutMs

        // Run validation on a background thread (not the actor)
        Task.detached(priority: .utility) { [weak self] in
            let results = AutoValidateWorker.validate(
                path: item.path,
                projectRoot: item.projectRoot,
                categories: categories,
                timeoutMs: timeoutMs,
                registry: ValidatorRegistry.shared
            )

            // Store results in DB
            let db = SessionDatabase.shared
            for result in results {
                db.insertValidationResult(
                    sessionId: item.sessionId,
                    filePath: result.path,
                    validatorName: result.validatorName,
                    category: result.category,
                    exitCode: result.exitCode,
                    rawOutput: result.rawOutput,
                    advisory: result.advisory,
                    durationMs: result.durationMs
                )
            }

            // Also record as a token_event for Agent Timeline visibility
            if !results.isEmpty {
                let totalDuration = results.reduce(0) { $0 + $1.durationMs }
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
}
