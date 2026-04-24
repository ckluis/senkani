import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-autovalidate-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanupDB(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

private func eventCount(_ db: SessionDatabase, _ type: String, projectRoot: String? = nil) -> Int {
    db.flushWrites()
    return db.eventCounts(projectRoot: projectRoot, prefix: type)
        .filter { $0.eventType == type }
        .reduce(0) { $0 + $1.count }
}

private func parseResponse(_ data: Data) -> (decision: String?, reason: String?) {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let hookOutput = json["hookSpecificOutput"] as? [String: Any] else {
        return (nil, nil)
    }
    return (hookOutput["permissionDecision"] as? String,
            hookOutput["permissionDecisionReason"] as? String)
}

// MARK: - Suite 1: AutoValidateConfig

@Suite("AutoValidateConfig")
struct AutoValidateConfigTests {

    @Test func defaultIsDisabled() {
        let config = AutoValidateConfig.default
        #expect(config.enabled == false)
        #expect(config.categories == ["syntax", "type"])
        #expect(config.debounceMs == 300)
        #expect(config.timeoutMs == 5000)
        #expect(config.maxConcurrent == 2)
    }

    @Test func categoryFilteringRejectsUnknown() {
        let config = AutoValidateConfig(categories: ["syntax", "bogus", "type", "invalid"])
        #expect(config.categories == ["syntax", "type"], "Unknown categories should be stripped")
    }

    @Test func excludePathsMatchGlobs() {
        let config = AutoValidateConfig(excludePaths: ["node_modules/**", "dist/**", "*.generated.*"])
        #expect(config.isExcluded(relativePath: "node_modules/foo/bar.ts"))
        #expect(config.isExcluded(relativePath: "dist/bundle.js"))
        #expect(!config.isExcluded(relativePath: "src/main.swift"))
    }

    @Test func clampingEnforcedOnBoundaryValues() {
        let config = AutoValidateConfig(debounceMs: -1, timeoutMs: 0, maxConcurrent: 100)
        #expect(config.debounceMs == 50, "debounceMs should clamp to minimum 50")
        #expect(config.timeoutMs == 1000, "timeoutMs should clamp to minimum 1000")
        #expect(config.maxConcurrent == 8, "maxConcurrent should clamp to maximum 8")
    }
}

// MARK: - Suite 2: DiagnosticRewriter

@Suite("DiagnosticRewriter")
struct DiagnosticRewriterTests {

    @Test func swiftErrorRewritten() {
        let output = "foo.swift:12:5: error: cannot find 'bar' in scope"
        let result = DiagnosticRewriter.rewrite(rawOutput: output, validatorName: "swiftc", filePath: "foo.swift")
        #expect(result.contains("'bar' is undefined"), "Should rewrite Swift scope error: \(result)")
        #expect(result.contains("Re-save to re-validate"), "Should include re-save instruction")
    }

    @Test func typescriptErrorRewritten() {
        let output = "bar.ts:47:3: error TS2322: Type 'string' is not assignable to type 'number'."
        let result = DiagnosticRewriter.rewrite(rawOutput: output, validatorName: "tsc", filePath: "bar.ts")
        #expect(result.contains("type mismatch"), "Should rewrite TS2322: \(result)")
    }

    @Test func unknownErrorGetsFallback() {
        let output = "baz.rs:8: some completely unknown error message"
        let result = DiagnosticRewriter.rewrite(rawOutput: output, validatorName: "rustc", filePath: "baz.rs")
        #expect(!result.isEmpty, "Should produce a fallback advisory")
        #expect(result.contains("Re-save to re-validate"), "Fallback should include re-save instruction")
    }

    @Test func outputCappedAt5Diagnostics() {
        let lines = (1...10).map { "foo.swift:\($0):1: error: cannot find 'x\($0)' in scope" }
        let output = lines.joined(separator: "\n")
        let result = DiagnosticRewriter.rewrite(rawOutput: output, validatorName: "swiftc", filePath: "foo.swift")
        let resultLines = result.components(separatedBy: "\n").filter { !$0.isEmpty }
        // Should have 5 diagnostics + 1 "and N more" line
        #expect(resultLines.count <= 6, "Should cap at 5 diagnostics + overflow: got \(resultLines.count)")
        #expect(result.contains("and 5 more"), "Should mention remaining issues")
    }
}

// MARK: - Suite 3: SessionDatabase Validation Results

@Suite("SessionDatabase — Validation Results")
struct ValidationResultsDBTests {

    @Test func insertAndFetch() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/test")

        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/foo.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "error: cannot find 'bar'",
            advisory: "'bar' is undefined.", durationMs: 120
        )
        db.flushWrites()

        let results = db.pendingValidationAdvisories(sessionId: sid)
        #expect(results.count == 1, "Should fetch 1 undelivered result")
        #expect(results.first?.advisory == "'bar' is undefined.")
        #expect(results.first?.exitCode == 1)
        #expect(results.first?.outcome == "advisory")
    }

    @Test func fetchMarksDelivered() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/test")

        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/foo.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: nil,
            advisory: "error found", durationMs: 50
        )
        db.flushWrites()

        let first = db.pendingValidationAdvisories(sessionId: sid)
        #expect(first.count == 1, "First fetch should return the result")

        let stillPending = db.pendingValidationAdvisories(sessionId: sid)
        #expect(stillPending.count == 1, "Fetch alone must not mark surfaced")

        db.markValidationAdvisoriesSurfaced(ids: first.map(\.id))
        db.flushWrites()

        let second = db.pendingValidationAdvisories(sessionId: sid)
        #expect(second.isEmpty, "After mark surfaced, pending fetch should be empty")
        #expect(db.validationResults(sessionId: sid).first?.surfacedAt != nil)
    }

    @Test func onlyErrorsReturned() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/test")

        // Insert a success (exitCode 0) and an error (exitCode 1)
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/ok.swift",
            validatorName: "swiftc", category: "syntax",
            exitCode: 0, rawOutput: nil,
            advisory: "all good", durationMs: 30
        )
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/bad.swift",
            validatorName: "swiftc", category: "syntax",
            exitCode: 1, rawOutput: "error found",
            advisory: "fix this", durationMs: 40
        )
        db.flushWrites()

        let results = db.pendingValidationAdvisories(sessionId: sid)
        #expect(results.count == 1, "Should only return errors, not successes")
        #expect(results.first?.advisory == "fix this")
    }

    @Test func cleanAndDroppedOutcomesInspectableButNotPending() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/test")

        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/ok.swift",
            validatorName: "swiftc", category: "syntax",
            exitCode: 0, rawOutput: nil,
            advisory: "", durationMs: 10,
            outcome: "clean"
        )
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/spawn.swift",
            validatorName: "swiftc", category: "syntax",
            exitCode: -1, rawOutput: "spawn failed",
            advisory: "spawn failed", durationMs: 1,
            outcome: "dropped", reason: "spawn_failed"
        )
        db.flushWrites()

        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
        #expect(db.validationResults(sessionId: sid, outcome: "clean").count == 1)
        let dropped = db.validationResults(sessionId: sid, outcome: "dropped")
        #expect(dropped.count == 1)
        #expect(dropped.first?.reason == "spawn_failed")
    }

    @Test func pruneOldResults() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let sid = db.createSession(projectRoot: "/tmp/test")

        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/old.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: nil,
            advisory: "old error", durationMs: 10
        )
        db.flushWrites()

        // Backdate the result
        db.executeRawSQL("UPDATE validation_results SET created_at = \(Date().addingTimeInterval(-100000).timeIntervalSince1970)")

        // Prune
        db.pruneValidationResults(olderThanHours: 24)
        db.flushWrites()

        let results = db.pendingValidationAdvisories(sessionId: sid)
        #expect(results.isEmpty, "Old results should be pruned")
    }
}

// MARK: - Suite 4: HookRouter Integration

@Suite("HookRouter — Auto-Validate Integration", .serialized)
struct HookRouterAutoValidateTests {

    @Test func postToolUseEditReturnsPassthrough() {
        // PostToolUse should always passthrough (never block)
        let event: [String: Any] = [
            "tool_name": "Edit",
            "hook_event_name": "PostToolUse",
            "tool_input": ["file_path": "/tmp/test/foo.swift"],
            "cwd": "/tmp/test",
            "session_id": "test-session",
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "PostToolUse should always passthrough")
    }

    @Test func postToolUseWriteReturnsPassthrough() {
        let event: [String: Any] = [
            "tool_name": "Write",
            "hook_event_name": "PostToolUse",
            "tool_input": ["file_path": "/tmp/test/bar.swift"],
            "cwd": "/tmp/test",
            "session_id": "test-session",
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        let json = String(data: response, encoding: .utf8)
        #expect(json == "{}", "PostToolUse Write should passthrough")
    }

    @Test func pendingAdvisorySurvivesPassthroughPreToolUse() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        defer { HookRouter.validationDatabase = .shared }

        let sid = "advisory-test-session"
        HookRouter.validationDatabase = db
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/broken.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "error at line 12",
            advisory: "'bar' is undefined. Add import Bar.", durationMs: 80
        )
        db.flushWrites()

        let event: [String: Any] = [
            "tool_name": "Bash",
            "hook_event_name": "PreToolUse",
            "tool_input": ["command": "git commit --dry-run"],
            "cwd": "/tmp/test",
            "session_id": sid,
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        #expect(response == HookRouter.passthroughResponse)
        db.flushWrites()
        #expect(db.pendingValidationAdvisories(sessionId: sid).count == 1,
                "passthrough response must not consume advisory")
    }

    @Test func pendingAdvisoryAppendsOnceToDenyResponse() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        defer { HookRouter.validationDatabase = .shared }

        let sid = "advisory-deny-session"
        HookRouter.validationDatabase = db
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/broken.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "error at line 12",
            advisory: "'bar' is undefined. Add import Bar.", durationMs: 80
        )
        db.flushWrites()

        let event: [String: Any] = [
            "tool_name": "Read",
            "hook_event_name": "PreToolUse",
            "tool_input": ["file_path": "broken.swift"],
            "cwd": "/tmp/test",
            "session_id": sid,
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        let parsed = parseResponse(response)
        #expect(parsed.decision == "deny")
        #expect(parsed.reason?.contains("'bar' is undefined") == true)
        db.flushWrites()
        #expect(db.pendingValidationAdvisories(sessionId: sid).isEmpty)
        #expect(eventCount(db, "auto_validate.delivered", projectRoot: "/tmp/test") == 1)

        let second = HookRouter.handle(eventJSON: eventData)
        let secondParsed = parseResponse(second)
        #expect(secondParsed.reason?.contains("'bar' is undefined") == false,
                "surfaced advisory must not repeat")
    }

    @Test func advisoryScopeDoesNotCrossSessions() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        defer { HookRouter.validationDatabase = .shared }

        HookRouter.validationDatabase = db
        db.insertValidationResult(
            sessionId: "other-session", filePath: "/tmp/test/broken.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "error",
            advisory: "other session diagnostic", durationMs: 1
        )
        db.flushWrites()

        let event: [String: Any] = [
            "tool_name": "Read",
            "hook_event_name": "PreToolUse",
            "tool_input": ["file_path": "broken.swift"],
            "cwd": "/tmp/test",
            "session_id": "current-session",
        ]
        let response = HookRouter.handle(eventJSON: try! JSONSerialization.data(withJSONObject: event))
        let parsed = parseResponse(response)
        #expect(parsed.reason?.contains("other session diagnostic") == false)
    }
}

// MARK: - Suite 5: AutoValidateWorker

@Suite("AutoValidateWorker — Subprocess")
struct AutoValidateWorkerTests {

    @Test func missingBinaryHandledGracefully() {
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "fake", language: "test", command: "/nonexistent/binary",
                args: [], extensions: ["test"], category: "syntax",
                installed: true
            )
        ])

        let results = AutoValidateWorker.validate(
            path: "/tmp/test.test",
            projectRoot: "/tmp",
            categories: ["syntax"],
            timeoutMs: 5000,
            registry: registry
        )

        #expect(results.isEmpty, "Missing validator binaries should not produce user advisories")
    }

    @Test func missingBinaryProducesDroppedAttempt() {
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "fake", language: "test", command: "/nonexistent/binary",
                args: [], extensions: ["test"], category: "syntax",
                installed: true
            )
        ])

        let attempts = AutoValidateWorker.validateAttempts(
            path: "/tmp/test.test",
            projectRoot: "/tmp",
            categories: ["syntax"],
            timeoutMs: 5000,
            registry: registry
        )

        #expect(attempts.count == 1)
        #expect(attempts.first?.outcome == .dropped)
        #expect(attempts.first?.reason == "spawn_failed")
    }

    @Test func cleanRunProducesCleanAttempt() {
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "clean-sh", language: "test", command: "/bin/sh",
                args: ["-c", "exit 0"], extensions: ["test"], category: "syntax",
                installed: true
            )
        ])

        let attempts = AutoValidateWorker.validateAttempts(
            path: "/tmp/test.test",
            projectRoot: "/tmp",
            categories: ["syntax"],
            timeoutMs: 5000,
            registry: registry
        )

        #expect(attempts.count == 1)
        #expect(attempts.first?.outcome == .clean)
    }

    @Test func categoryFilteringApplied() {
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "syntax-check", language: "swift", command: "swiftc",
                args: ["-typecheck"], extensions: ["swift"], category: "syntax",
                enabled: true, installed: true
            ),
            ValidatorDef(
                name: "linter", language: "swift", command: "swiftlint",
                args: [], extensions: ["swift"], category: "lint",
                enabled: true, installed: true
            ),
        ])

        // Only request "syntax" category — lint should be skipped
        let validators = registry.validatorsFor(extension: "swift")
        let filtered = validators.filter { ["syntax"].contains($0.category) }
        #expect(filtered.count == 1, "Should only have syntax validator")
        #expect(filtered.first?.name == "syntax-check")
    }
}

// MARK: - Suite 6: AutoValidateQueue

@Suite("AutoValidateQueue — Enqueue Logic")
struct AutoValidateQueueTests {

    @Test func excludedPathSkipped() async {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/project"
        let queue = AutoValidateQueue(
            database: db,
            configLoader: { _ in AutoValidateConfig(enabled: true, excludePaths: ["node_modules/**"]) }
        )

        // Enqueue a file in node_modules — should be skipped
        await queue.enqueue(
            path: "/tmp/project/node_modules/foo.ts",
            sessionId: "test",
            projectRoot: root
        )
        await queue.drainForTesting()

        // Queue should have nothing running
        let count = await queue.runningCount
        #expect(count == 0, "Excluded path should not enqueue")
        #expect(eventCount(db, "auto_validate.skipped_excluded", projectRoot: root) == 1)
    }

    @Test func unknownExtensionSkipped() async {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/project"
        let queue = AutoValidateQueue(
            database: db,
            configLoader: { _ in AutoValidateConfig(enabled: true) }
        )

        // .xyz has no validators registered
        await queue.enqueue(
            path: "/tmp/project/readme.xyz",
            sessionId: "test",
            projectRoot: root
        )
        await queue.drainForTesting()

        let count = await queue.runningCount
        #expect(count == 0, "Unknown extension should not enqueue")
        #expect(eventCount(db, "auto_validate.skipped_no_validator", projectRoot: root) == 1)
    }

    @Test func cleanValidationPersistsOutcomeAndCounters() async {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }
        let root = "/tmp/senkani-queue-clean-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let sid = "queue-clean"
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "clean-sh", language: "test", command: "/bin/sh",
                args: ["-c", "exit 0"], extensions: ["test"], category: "syntax",
                installed: true
            )
        ])
        let queue = AutoValidateQueue(
            database: db,
            registry: registry,
            configLoader: { _ in AutoValidateConfig(enabled: true, debounceMs: 50, timeoutMs: 1000, maxConcurrent: 1) }
        )

        let filePath = "\(root)/ok.test"
        FileManager.default.createFile(atPath: filePath, contents: Data("ok\n".utf8))
        await queue.enqueue(path: filePath, sessionId: sid, projectRoot: root)
        await queue.drainForTesting()

        let rows = db.validationResults(sessionId: sid, outcome: "clean")
        #expect(rows.count == 1)
        #expect(eventCount(db, "auto_validate.enqueued", projectRoot: root) == 1)
        #expect(eventCount(db, "auto_validate.started", projectRoot: root) == 1)
        #expect(eventCount(db, "auto_validate.clean", projectRoot: root) == 1)
    }
}

// MARK: - Suite 7: Safety

@Suite("AutoValidate — Safety")
struct AutoValidateSafetyTests {

    @Test func disabledConfigMeansNoValidation() {
        // Default config has enabled=false
        let config = AutoValidateConfig.default
        #expect(config.enabled == false)

        // PostToolUse with disabled config → passthrough (no enqueue)
        let event: [String: Any] = [
            "tool_name": "Edit",
            "hook_event_name": "PostToolUse",
            "tool_input": ["file_path": "/tmp/foo.swift"],
            "cwd": "/tmp",
            "session_id": "test",
        ]
        let eventData = try! JSONSerialization.data(withJSONObject: event)
        let response = HookRouter.handle(eventJSON: eventData)
        #expect(response == HookRouter.passthroughResponse, "Disabled config should passthrough")
    }

    @Test func emptyOutputProducesNoAdvisory() {
        let result = DiagnosticRewriter.rewrite(rawOutput: "", validatorName: "swiftc", filePath: "foo.swift")
        #expect(result.isEmpty, "Empty output should produce no advisory")
    }
}
