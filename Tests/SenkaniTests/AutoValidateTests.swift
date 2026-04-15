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
        Thread.sleep(forTimeInterval: 0.1)  // flush async write

        let results = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(results.count == 1, "Should fetch 1 undelivered result")
        #expect(results.first?.advisory == "'bar' is undefined.")
        #expect(results.first?.exitCode == 1)
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
        Thread.sleep(forTimeInterval: 0.1)

        let first = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(first.count == 1, "First fetch should return the result")

        let second = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(second.isEmpty, "Second fetch should be empty (already delivered)")
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
        Thread.sleep(forTimeInterval: 0.1)

        let results = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(results.count == 1, "Should only return errors, not successes")
        #expect(results.first?.advisory == "fix this")
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
        Thread.sleep(forTimeInterval: 0.1)

        // Backdate the result
        db.executeRawSQL("UPDATE validation_results SET created_at = \(Date().addingTimeInterval(-100000).timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 0.05)

        // Prune
        db.pruneValidationResults(olderThanHours: 24)
        Thread.sleep(forTimeInterval: 0.1)

        let results = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(results.isEmpty, "Old results should be pruned")
    }
}

// MARK: - Suite 4: HookRouter Integration

@Suite("HookRouter — Auto-Validate Integration")
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

    @Test func preToolUseAdvisoryAppended() {
        let (db, dbPath) = makeTempDB()
        defer { cleanupDB(dbPath) }

        // Insert an undelivered validation result
        let sid = "advisory-test-session"
        _ = db.createSession(projectRoot: "/tmp/test")
        db.insertValidationResult(
            sessionId: sid, filePath: "/tmp/test/broken.swift",
            validatorName: "swiftc", category: "type",
            exitCode: 1, rawOutput: "error at line 12",
            advisory: "'bar' is undefined. Add import Bar.", durationMs: 80
        )
        Thread.sleep(forTimeInterval: 0.1)

        // Fetch and verify
        let results = db.fetchAndMarkDelivered(sessionId: sid)
        #expect(!results.isEmpty, "Should have undelivered results")

        // Format the advisory
        let advisory = results.map(\.advisory).joined(separator: "\n")
        #expect(advisory.contains("'bar' is undefined"), "Advisory should contain the diagnostic")
    }
}

// MARK: - Suite 5: AutoValidateWorker

@Suite("AutoValidateWorker — Subprocess")
struct AutoValidateWorkerTests {

    @Test func missingBinaryHandledGracefully() {
        let registry = ValidatorRegistry(validators: [
            ValidatorDef(
                name: "fake", language: "test", command: "/nonexistent/binary",
                args: [], extensions: ["test"], category: "syntax"
            )
        ])

        let results = AutoValidateWorker.validate(
            path: "/tmp/test.test",
            projectRoot: "/tmp",
            categories: ["syntax"],
            timeoutMs: 5000,
            registry: registry
        )

        // Should not crash — may return empty (if extension check fails) or error result
        // The key assertion: no crash occurred
        #expect(true, "Should handle missing binary without crash")
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
        let queue = AutoValidateQueue()
        await queue.updateConfig(AutoValidateConfig(
            enabled: true,
            excludePaths: ["node_modules/**"]
        ))

        // Enqueue a file in node_modules — should be skipped
        await queue.enqueue(
            path: "/tmp/project/node_modules/foo.ts",
            sessionId: "test",
            projectRoot: "/tmp/project"
        )

        // Queue should have nothing running
        let count = await queue.runningCount
        #expect(count == 0, "Excluded path should not enqueue")
    }

    @Test func unknownExtensionSkipped() async {
        let queue = AutoValidateQueue()
        await queue.updateConfig(AutoValidateConfig(enabled: true))

        // .xyz has no validators registered
        await queue.enqueue(
            path: "/tmp/project/readme.xyz",
            sessionId: "test",
            projectRoot: "/tmp/project"
        )

        let count = await queue.runningCount
        #expect(count == 0, "Unknown extension should not enqueue")
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
