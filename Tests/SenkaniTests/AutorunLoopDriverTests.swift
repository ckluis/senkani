import Testing
import Foundation
@testable import Core

/// U.3 (LEG 1) — coverage for the Core-pure autorun spine: the
/// `TaskDecomposer`, the `AutorunContractStore` durability/resume seam, and
/// the `AutorunLoopDriver` gate/notification/dry-run logic.
///
/// Every test is hermetic: the decomposer is pure, the contract store
/// writes under an injected temp root, and the loop driver runs against a
/// temp `SessionDatabase` with an injected `MockCommandRunner` +
/// `MockNotificationSink` — NO real process, network, or TTY.
///
/// `.serialized` because the loop driver writes to `ValidationStore`
/// (async-dispatched to the DB queue) — the suite is concurrency-adjacent
/// and follows the DB-touching-suite reflex.
@Suite("U.3 autorun spine (leg 1)", .serialized)
struct AutorunLoopDriverTests {

    // MARK: - Helpers

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-u3-autorun-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    private static func tempRoot() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("senkani-u3-autorun-store-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    // MARK: - TaskDecomposer

    @Test("decompose: one top-level bullet → one contract; default gate commands when unannotated")
    func decomposeBulletsToContracts() {
        let md = """
        # My overnight tasks

        - Fix the flaky timer test
        - Rename the legacy helper
        * Also a star bullet
        + And a plus bullet

        Not a bullet — ignored.
          - nested bullet ignored (indented)
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        #expect(contracts.count == 4)
        #expect(contracts.map(\.objective) == [
            "Fix the flaky timer test",
            "Rename the legacy helper",
            "Also a star bullet",
            "And a plus bullet",
        ])
        // No annotation ⇒ default test/lint gate.
        for c in contracts {
            #expect(c.commands == TaskDecomposer.defaultCommands)
            #expect(c.fileScope.isEmpty)
            #expect(c.acceptance.isEmpty)
            #expect(c.reviewLevel == .none)
        }
    }

    @Test("decompose: inline cmd/files annotations populate commands + fileScope; objective is clean")
    func decomposeInlineAnnotations() {
        let md = """
        - Patch the parser [cmd: swift build; swift test --filter ParserTests] [files: Sources/Core/Parser.swift, Tests/ParserTests.swift]
        - Tidy docs -- cmds: echo lint && echo build; files: docs/x.md
        - Keep [brackets] that are not annotations verbatim
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        #expect(contracts.count == 3)

        #expect(contracts[0].objective == "Patch the parser")
        #expect(contracts[0].commands == ["swift build", "swift test --filter ParserTests"])
        #expect(contracts[0].fileScope == ["Sources/Core/Parser.swift", "Tests/ParserTests.swift"])

        #expect(contracts[1].objective == "Tidy docs")
        #expect(contracts[1].commands == ["echo lint", "echo build"])
        #expect(contracts[1].fileScope == ["docs/x.md"])

        // An unrecognized `[brackets]` span stays verbatim in the objective.
        #expect(contracts[2].objective == "Keep [brackets] that are not annotations verbatim")
        #expect(contracts[2].commands == TaskDecomposer.defaultCommands)
    }

    @Test("decompose: deterministic ids + shared workstream id via injected factory")
    func decomposeDeterministicIds() {
        let ws = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        var counter = 0
        let ids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ]
        let contracts = TaskDecomposer().decompose(
            markdown: "- one\n- two",
            workstreamID: ws,
            idFactory: { defer { counter += 1 }; return ids[counter] }
        )
        #expect(contracts.map(\.id) == ids)
        #expect(contracts.allSatisfy { $0.workstreamID == ws })
    }

    @Test("decompose(contentsOfFile:) throws unreadable for a missing path")
    func decomposeMissingFileThrows() {
        let missing = "/tmp/senkani-u3-does-not-exist-\(UUID().uuidString).md"
        #expect(throws: TaskDecomposer.DecomposeError.unreadable(path: missing)) {
            _ = try TaskDecomposer().decompose(contentsOfFile: missing)
        }
    }

    // MARK: - AutorunContractStore (durability + resume round-trip)

    @Test("contracts.json: persist → load round-trip is field-equal; byte-stable re-encode")
    func contractStoreRoundTrip() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let md = "- alpha [cmd: swift build]\n- beta [files: a.swift]"
        let contracts = TaskDecomposer().decompose(markdown: md)
        let runId = "20260613-000000-deadbeef"

        let dest = try AutorunContractStore.persist(runId: runId, contracts: contracts, rootDir: root)
        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(dest.lastPathComponent == "contracts.json")

        // Resume seam: re-read returns the same contracts.
        let loaded = AutorunContractStore.load(runId: runId, rootDir: root)
        #expect(loaded == contracts)

        // The on-disk bytes are byte-stable through the canonical encoder
        // (re-encode the loaded envelope == the file on disk).
        let envelope = AutorunContractStore.loadEnvelope(runId: runId, rootDir: root)
        let onDisk = try Data(contentsOf: dest)
        let reencoded = try AutorunContractStore.canonicalEncoder().encode(envelope!)
        #expect(onDisk == reencoded)
        #expect(envelope?.runId == runId)
        #expect(envelope?.schemaVersion == AutorunContractStore.schemaVersion)
    }

    @Test("contracts.json: load returns nil for a missing run, a corrupt file, and a future schema")
    func contractStoreLoadFailsSafe() throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Missing run.
        #expect(AutorunContractStore.load(runId: "never-written", rootDir: root) == nil)

        // Corrupt file.
        let corruptRun = "corrupt"
        let corruptURL = AutorunContractStore.contractsURL(runId: corruptRun, rootDir: root)
        try FileManager.default.createDirectory(at: corruptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: corruptURL)
        #expect(AutorunContractStore.load(runId: corruptRun, rootDir: root) == nil)

        // Future schema fails safe (treated as no durable plan).
        let futureRun = "future"
        let futureURL = AutorunContractStore.contractsURL(runId: futureRun, rootDir: root)
        try FileManager.default.createDirectory(at: futureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let future = AutorunContractStore.Envelope(
            schemaVersion: AutorunContractStore.schemaVersion + 1,
            runId: futureRun,
            contracts: []
        )
        try AutorunContractStore.canonicalEncoder().encode(future).write(to: futureURL)
        #expect(AutorunContractStore.load(runId: futureRun, rootDir: root) == nil)
    }

    @Test("contracts.json: safeRunId neutralizes path-escape attempts")
    func contractStoreSafeRunId() {
        // A `../` escape collapses to safe characters under the autorun root.
        let escaped = AutorunContractStore.safeRunId("../../etc/passwd")
        #expect(!escaped.contains("/"))
        #expect(!escaped.hasPrefix("."))
        #expect(AutorunContractStore.safeRunId("") == "run")
    }

    // MARK: - AutorunLoopDriver — dry-run

    @Test("dry-run: prints the plan, executes NO command, sends NO notification")
    func dryRunExecutesNothing() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner()
        let sink = MockNotificationSink()
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let contracts = TaskDecomposer().decompose(markdown: "- a [cmd: swift build]\n- b")
        var printed: [String] = []
        let lines = driver.dryRun(contracts: contracts, output: { printed.append($0) })

        // Nothing executed, nothing delivered.
        #expect(runner.ran.isEmpty)
        #expect(sink.delivered.isEmpty)
        // The plan names both tasks + their gates.
        #expect(printed.contains { $0.contains("[1/2]") && $0.contains("a") })
        #expect(printed.contains { $0.contains("[2/2]") && $0.contains("b") })
        #expect(printed.contains { $0.contains("swift build") })
        #expect(lines.contains { $0.contains("autorun plan") })
    }

    // MARK: - AutorunLoopDriver — live gate

    @Test("validation clean → commit-event notifyDone, validation rows written clean")
    func cleanTaskCommits() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Every command exits 0.
        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: "ok"))
        let sink = MockNotificationSink()
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let contracts = TaskDecomposer().decompose(markdown: "- only task [cmd: echo a; echo b]")
        let runId = "clean-\(UUID().uuidString.prefix(8))"
        let result = driver.run(contracts: contracts, runId: String(runId), output: { _ in })

        #expect(result.allCommitted)
        #expect(result.outcomes == [.committed(taskIndex: 0)])
        // Both gate commands ran.
        #expect(runner.ran == ["echo a", "echo b"])
        // One notifyDone, no failure.
        #expect(sink.delivered.count == 1)
        if case .notifyDone(let tool, let summary) = sink.delivered[0] {
            #expect(tool == "autorun")
            #expect(summary.contains("committed"))
        } else {
            Issue.record("expected notifyDone, got \(sink.delivered[0])")
        }
        // Two clean validation rows landed under this run's session.
        db.flushWrites()
        let rows = db.validationResults(sessionId: AutorunLoopDriver.sessionId(runId: String(runId)))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.outcome == "clean" })
    }

    @Test("validation fail → notifyFailure + halt + stop; no later command runs")
    func failingTaskHaltsAndStops() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // The second command in task 1 fails; task 2 must never run.
        let runner = MockCommandRunner(
            canned: ["boom": CommandRunResult(exitCode: 7, output: "kaboom")],
            defaultResult: CommandRunResult(exitCode: 0, output: nil)
        )
        let sink = MockNotificationSink()
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let md = """
        - first task [cmd: echo ok; boom; never runs]
        - second task [cmd: should-not-run]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let runId = "fail-\(UUID().uuidString.prefix(8))"
        let result = driver.run(contracts: contracts, runId: String(runId), output: { _ in })

        #expect(!result.allCommitted)
        // Halted at task 0 on `boom`.
        #expect(result.outcomes.count == 1)
        if case .halted(let idx, let cmd, let code) = result.outcomes[0] {
            #expect(idx == 0)
            #expect(cmd == "boom")
            #expect(code == 7)
        } else {
            Issue.record("expected halted outcome, got \(result.outcomes[0])")
        }
        // The command AFTER the failure in task 1 never ran; task 2 never ran.
        #expect(runner.ran == ["echo ok", "boom"])
        #expect(!runner.ran.contains("never runs"))
        #expect(!runner.ran.contains("should-not-run"))
        // Exactly one notifyFailure, no notifyDone.
        #expect(sink.delivered.count == 1)
        if case .notifyFailure(let tool, let reason) = sink.delivered[0] {
            #expect(tool == "autorun")
            #expect(reason.contains("boom") && reason.contains("7"))
        } else {
            Issue.record("expected notifyFailure, got \(sink.delivered[0])")
        }
    }

    @Test("mixed tasks: first two clean commit, third fails → stop at first failure")
    func mixedTasksStopAtFirstFailure() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(
            canned: ["fail3": CommandRunResult(exitCode: 2, output: nil)],
            defaultResult: CommandRunResult(exitCode: 0, output: nil)
        )
        let sink = MockNotificationSink()
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let md = """
        - t1 [cmd: ok1]
        - t2 [cmd: ok2]
        - t3 [cmd: fail3]
        - t4 [cmd: ok4]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let runId = "mixed-\(UUID().uuidString.prefix(8))"
        let result = driver.run(contracts: contracts, runId: String(runId), output: { _ in })

        #expect(!result.allCommitted)
        // Two commits then a halt; task 4 never runs.
        #expect(result.outcomes == [
            .committed(taskIndex: 0),
            .committed(taskIndex: 1),
            .halted(taskIndex: 2, failedCommand: "fail3", exitCode: 2),
        ])
        #expect(runner.ran == ["ok1", "ok2", "fail3"])
        #expect(!runner.ran.contains("ok4"))
        // Two notifyDone + one notifyFailure, in order.
        #expect(sink.delivered.count == 3)
        if case .notifyDone = sink.delivered[0], case .notifyDone = sink.delivered[1],
           case .notifyFailure = sink.delivered[2] {
            // ok
        } else {
            Issue.record("expected [done, done, failure], got \(sink.delivered)")
        }
    }

    @Test("sessionId scoping: a prior run's rows do not bleed into this run's gate")
    func sessionIdScopingIsolatesRuns() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Plant an ADVISORY (non-clean) autorun row under a DIFFERENT run's
        // session. If the gate were not session-scoped this would poison a
        // clean run.
        let priorSession = AutorunLoopDriver.sessionId(runId: "prior-run")
        db.insertValidationResult(
            sessionId: priorSession,
            filePath: "x",
            validatorName: "autorun",
            category: "autorun",
            exitCode: 1,
            rawOutput: nil,
            advisory: "prior failure",
            durationMs: 0,
            outcome: "advisory",
            reason: "exit_1"
        )
        db.flushWrites()

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let contracts = TaskDecomposer().decompose(markdown: "- clean task [cmd: echo ok]")
        let result = driver.run(contracts: contracts, runId: "fresh-run", output: { _ in })

        // The fresh run commits despite the prior run's advisory row.
        #expect(result.allCommitted)
        #expect(result.outcomes == [.committed(taskIndex: 0)])
    }

    // MARK: - Unattended-refusal precondition

    @Test("unattended-refusal: refuses unattended + unseeded, names the doctor seed command")
    func unattendedRefusalNamesDoctorCommand() {
        // Unattended (no TTY) + no Pushover seed ⇒ refuse, message names the
        // seed command.
        let refusal = AutorunLoopDriver.unattendedRefusalReason(
            pushoverSeeded: false,
            attendedOnTTY: false
        )
        #expect(refusal != nil)
        #expect(refusal!.contains("senkani doctor --seed-pushover-key"))

        // Seeded ⇒ allowed even unattended.
        #expect(AutorunLoopDriver.unattendedRefusalReason(pushoverSeeded: true, attendedOnTTY: false) == nil)
        // Attended ⇒ always allowed (operator sees halts directly).
        #expect(AutorunLoopDriver.unattendedRefusalReason(pushoverSeeded: false, attendedOnTTY: true) == nil)
        #expect(AutorunLoopDriver.unattendedRefusalReason(pushoverSeeded: true, attendedOnTTY: true) == nil)
    }

    // MARK: - PushoverSink wiring with the fake transport (leg-1 observability)

    @Test("PushoverSink wiring: commit + halt events are observable via the spy, no real network")
    func pushoverWiringObservableViaSpy() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Wire the loop's sink as a PushoverSink over the fake transport +
        // spy telemetry — exactly the leg-1 production shape (no real push).
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: .synthetic,
            transport: transport,
            telemetry: telemetry,
            allowEngine: EgressPolicy.pushoverAllowEngine()
        )

        let runner = MockCommandRunner(
            canned: ["bad": CommandRunResult(exitCode: 3, output: nil)],
            defaultResult: CommandRunResult(exitCode: 0, output: nil)
        )
        let driver = AutorunLoopDriver(database: db, commandRunner: runner, sink: sink)

        let md = """
        - good [cmd: ok]
        - bad task [cmd: bad]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let result = driver.run(contracts: contracts, runId: "push-\(UUID().uuidString.prefix(8))", output: { _ in })

        #expect(!result.allCommitted)
        // Two events crossed the fake transport: one done (good), one failure
        // (bad). Observable via the spy; no network touched.
        #expect(transport.sent.count == 2)
        #expect(transport.sent.map(\.message.eventClass) == ["notify_done", "notify_failure"])
        // Telemetry recorded both as delivered heartbeats.
        #expect(telemetry.records.count == 2)
        #expect(telemetry.records.allSatisfy { $0.outcome == .delivered })
        // Every request went ONLY to the pinned host.
        #expect(transport.sent.allSatisfy { $0.host == PushoverSink.host })
    }

    // MARK: - Supervision (LEG 2 — `--supervise-first N`)

    @Test("isSupervised predicate: true for indices < N, false for >= N; N=0 ⇒ none")
    func isSupervisedPredicate() {
        // N = 2 ⇒ indices 0,1 supervised; 2+ unattended.
        #expect(AutorunLoopDriver.isSupervised(taskIndex: 0, superviseFirst: 2))
        #expect(AutorunLoopDriver.isSupervised(taskIndex: 1, superviseFirst: 2))
        #expect(!AutorunLoopDriver.isSupervised(taskIndex: 2, superviseFirst: 2))
        #expect(!AutorunLoopDriver.isSupervised(taskIndex: 99, superviseFirst: 2))
        // N = 0 ⇒ nothing supervised.
        #expect(!AutorunLoopDriver.isSupervised(taskIndex: 0, superviseFirst: 0))
        #expect(!AutorunLoopDriver.isSupervised(taskIndex: 5, superviseFirst: 0))
    }

    @Test("supervise proceed → all commit; only indices < N prompted, with correct tuples")
    func superviseProceedAllCommit() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        // Canned .proceed for both prompts (and a .proceed fallback).
        let prompt = MockSupervisionPrompt(answers: [.proceed, .proceed])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let md = """
        - alpha [cmd: a0]
        - bravo [cmd: b0]
        - charlie [cmd: c0]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let result = driver.run(
            contracts: contracts,
            runId: "sup-proceed-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 2
        )

        #expect(result.allCommitted)
        #expect(result.outcomes == [
            .committed(taskIndex: 0),
            .committed(taskIndex: 1),
            .committed(taskIndex: 2),
        ])
        // Only indices 0 and 1 were prompted (index 2 ran unattended).
        let asked = prompt.asked
        #expect(asked.count == 2)
        #expect(asked.map(\.taskIndex) == [0, 1])
        #expect(asked.allSatisfy { $0.total == 3 })
        #expect(asked.map(\.objective) == ["alpha", "bravo"])
        // Three commit-event notifyDone, no failure.
        #expect(sink.delivered.count == 3)
        #expect(sink.delivered.allSatisfy {
            if case .notifyDone = $0 { return true } else { return false }
        })
    }

    @Test("supervise abort → notifyFailure + stop; later command never runs; abortedBySupervisor")
    func superviseAbortStops() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        // Abort at the very first prompt (index 0).
        let prompt = MockSupervisionPrompt(answers: [.abort])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let md = """
        - first [cmd: cmd-first]
        - second [cmd: cmd-second]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let result = driver.run(
            contracts: contracts,
            runId: "sup-abort-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 3
        )

        #expect(!result.allCommitted)
        #expect(result.outcomes == [.abortedBySupervisor(taskIndex: 0)])
        // Task 0's gate command ran; task 1's never did (the loop stopped).
        #expect(runner.ran == ["cmd-first"])
        #expect(!runner.ran.contains("cmd-second"))
        // Exactly one delivered event: a notifyFailure naming the abort. No
        // notifyDone.
        #expect(sink.delivered.count == 1)
        if case .notifyFailure(let tool, let reason) = sink.delivered[0] {
            #expect(tool == "autorun")
            #expect(reason.contains("abort"))
        } else {
            Issue.record("expected notifyFailure, got \(sink.delivered[0])")
        }
        #expect(!sink.delivered.contains {
            if case .notifyDone = $0 { return true } else { return false }
        })
        // The prompt was asked exactly once.
        #expect(prompt.asked.count == 1)
    }

    @Test("supervise scoped to first N: task N+1 advances with no prompt")
    func superviseScopedToFirstN() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        let prompt = MockSupervisionPrompt(answers: [.proceed])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let md = """
        - t0 [cmd: x0]
        - t1 [cmd: x1]
        - t2 [cmd: x2]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        let result = driver.run(
            contracts: contracts,
            runId: "sup-scope-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 1
        )

        #expect(result.allCommitted)
        #expect(result.outcomes == [
            .committed(taskIndex: 0),
            .committed(taskIndex: 1),
            .committed(taskIndex: 2),
        ])
        // The prompt was asked EXACTLY once — index 0 only.
        #expect(prompt.asked.count == 1)
        #expect(prompt.asked.map(\.taskIndex) == [0])
        // Tasks 1 & 2 advanced unattended.
        #expect(sink.delivered.count == 3)
    }

    @Test("gate FAILURE halts before the prompt: outcome .halted, prompt never consulted")
    func gateFailureHaltsBeforePrompt() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        // Task 0's command fails — the task must halt at the gate, never
        // reaching the supervision prompt.
        let runner = MockCommandRunner(
            canned: ["boom": CommandRunResult(exitCode: 9, output: nil)],
            defaultResult: CommandRunResult(exitCode: 0, output: nil)
        )
        let sink = MockNotificationSink()
        let prompt = MockSupervisionPrompt(answers: [.proceed])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let contracts = TaskDecomposer().decompose(markdown: "- doomed [cmd: boom]")
        let result = driver.run(
            contracts: contracts,
            runId: "sup-gatefail-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 3
        )

        #expect(!result.allCommitted)
        // A gate failure — NOT a supervisor abort.
        #expect(result.outcomes.count == 1)
        if case .halted(let idx, let cmd, let code) = result.outcomes[0] {
            #expect(idx == 0)
            #expect(cmd == "boom")
            #expect(code == 9)
        } else {
            Issue.record("expected .halted, got \(result.outcomes[0])")
        }
        // The prompt was NEVER consulted (gate runs first, halt returns early).
        #expect(prompt.asked.isEmpty)
        // The delivered event is a gate-failure notifyFailure (command + code).
        #expect(sink.delivered.count == 1)
        if case .notifyFailure(let tool, let reason) = sink.delivered[0] {
            #expect(tool == "autorun")
            #expect(reason.contains("boom") && reason.contains("9"))
        } else {
            Issue.record("expected notifyFailure, got \(sink.delivered[0])")
        }
    }

    @Test("superviseFirst:0 == leg-1 behavior: prompt never consulted, all commit")
    func superviseFirstZeroIsLegOneBehavior() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        // Would abort if ever consulted — proving it never is.
        let prompt = MockSupervisionPrompt(answers: [.abort], defaultAnswer: .abort)
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let md = """
        - one [cmd: o0]
        - two [cmd: t0]
        """
        let contracts = TaskDecomposer().decompose(markdown: md)
        // superviseFirst defaults to 0 — omit it.
        let result = driver.run(
            contracts: contracts,
            runId: "sup-zero-\(UUID().uuidString.prefix(8))",
            output: { _ in }
        )

        #expect(result.allCommitted)
        #expect(result.outcomes == [
            .committed(taskIndex: 0),
            .committed(taskIndex: 1),
        ])
        // The prompt was NEVER consulted.
        #expect(prompt.asked.isEmpty)
        // Two notifyDone, no failure (leg-1 counts).
        #expect(sink.delivered.count == 2)
        #expect(sink.delivered.allSatisfy {
            if case .notifyDone = $0 { return true } else { return false }
        })
    }

    @Test("supervised abort still leaves the aborted task's clean validation rows")
    func superviseAbortLeavesValidationRows() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        let prompt = MockSupervisionPrompt(answers: [.abort])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let runId = "sup-rows-\(UUID().uuidString.prefix(8))"
        let contracts = TaskDecomposer().decompose(markdown: "- task [cmd: vc0; vc1]")
        let result = driver.run(
            contracts: contracts,
            runId: runId,
            output: { _ in },
            superviseFirst: 1
        )

        #expect(result.outcomes == [.abortedBySupervisor(taskIndex: 0)])
        // Validation rows were written BEFORE the prompt (gate runs first), so
        // the supervised pause still leaves durable clean evidence.
        db.flushWrites()
        let rows = db.validationResults(sessionId: AutorunLoopDriver.sessionId(runId: runId))
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.outcome == "clean" })
    }

    // MARK: - Class gate (LEG 3 — `--allow-classes`)

    /// Build a single contract carrying an EXPLICIT `taskClass` via the new
    /// trailing init param.
    private static func classedContract(
        objective: String,
        commands: [String],
        taskClass: TaskClass?
    ) -> WorkstreamTaskContract {
        WorkstreamTaskContract(
            id: UUID(),
            workstreamID: UUID(),
            objective: objective,
            fileScope: [],
            allowedTools: [],
            dependencies: [],
            staleSpecAt: nil,
            budget: ContractBudget(tokensMax: 0, wallClockMaxS: 0),
            commands: commands,
            acceptance: [],
            reviewLevel: .none,
            taskClass: taskClass
        )
    }

    @Test("out-of-class task w/ non-empty allowlist routes through prompt; abort → pausedOutOfClass, not committed, even at superviseFirst=0")
    func outOfClassAbortPauses() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        // The class-gate ack is declined.
        let prompt = MockSupervisionPrompt(answers: [.abort])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        // A feature task under an allowlist of [.testFix] is out-of-class.
        let contracts = [
            Self.classedContract(objective: "add a shiny feature", commands: ["c0"], taskClass: .feature),
        ]
        let result = driver.run(
            contracts: contracts,
            runId: "ooc-abort-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 0,            // even fully unattended, the class gate fires
            allowList: [.testFix]
        )

        #expect(!result.allCommitted)
        #expect(result.outcomes == [.pausedOutOfClass(taskIndex: 0)])
        // The gate command ran (class gate is AFTER the validation gate).
        #expect(runner.ran == ["c0"])
        // The prompt was consulted once despite superviseFirst=0.
        #expect(prompt.asked.count == 1)
        // Exactly one notifyFailure, no notifyDone.
        #expect(sink.delivered.count == 1)
        if case .notifyFailure(let tool, let reason) = sink.delivered[0] {
            #expect(tool == "autorun")
            #expect(reason.contains("out-of-class"))
        } else {
            Issue.record("expected notifyFailure, got \(sink.delivered[0])")
        }
        #expect(!sink.delivered.contains {
            if case .notifyDone = $0 { return true } else { return false }
        })
    }

    @Test("in-list task w/ non-empty allowlist runs unattended: prompt NOT consulted, commits")
    func inListRunsUnattended() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        // Would abort if ever consulted — proving the in-list task never prompts.
        let prompt = MockSupervisionPrompt(answers: [.abort], defaultAnswer: .abort)
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let contracts = [
            Self.classedContract(objective: "fix flaky test", commands: ["c0"], taskClass: .testFix),
        ]
        let result = driver.run(
            contracts: contracts,
            runId: "inlist-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 0,
            allowList: [.testFix, .docs]
        )

        #expect(result.allCommitted)
        #expect(result.outcomes == [.committed(taskIndex: 0)])
        // The class gate allowed it unattended — the prompt was never consulted.
        #expect(prompt.asked.isEmpty)
        // One notifyDone, no failure.
        #expect(sink.delivered.count == 1)
        #expect(sink.delivered.allSatisfy {
            if case .notifyDone = $0 { return true } else { return false }
        })
    }

    @Test("out-of-class proceed falls through to commit")
    func outOfClassProceedCommits() {
        let (db, path) = Self.makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let runner = MockCommandRunner(defaultResult: CommandRunResult(exitCode: 0, output: nil))
        let sink = MockNotificationSink()
        let prompt = MockSupervisionPrompt(answers: [.proceed])
        let driver = AutorunLoopDriver(
            database: db, commandRunner: runner, sink: sink, supervisionPrompt: prompt
        )

        let contracts = [
            Self.classedContract(objective: "add a feature", commands: ["c0"], taskClass: .feature),
        ]
        let result = driver.run(
            contracts: contracts,
            runId: "ooc-proceed-\(UUID().uuidString.prefix(8))",
            output: { _ in },
            superviseFirst: 0,
            allowList: [.testFix]
        )

        #expect(result.allCommitted)
        #expect(result.outcomes == [.committed(taskIndex: 0)])
        // The class gate asked once; the operator allowed it through.
        #expect(prompt.asked.count == 1)
    }

    // MARK: - Envelope round-trip carrying taskClass (schemaVersion 2)

    @Test("envelope: a contract carrying a taskClass persists + reloads field-equal at schemaVersion 2")
    func envelopeTaskClassRoundTrip() throws {
        #expect(AutorunContractStore.schemaVersion == 2)

        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // Decompose stamps taskClass; "fix flaky test" → .testFix.
        let contracts = TaskDecomposer().decompose(markdown: "- fix flaky test\n- add a feature")
        #expect(contracts[0].taskClass == .testFix)
        #expect(contracts[1].taskClass == .feature)

        let runId = "20260614-000000-classed"
        let dest = try AutorunContractStore.persist(runId: runId, contracts: contracts, rootDir: root)

        let loaded = AutorunContractStore.load(runId: runId, rootDir: root)
        #expect(loaded == contracts)
        #expect(loaded?[0].taskClass == .testFix)
        #expect(loaded?[1].taskClass == .feature)

        // The envelope advertises the bumped schema version.
        let envelope = AutorunContractStore.loadEnvelope(runId: runId, rootDir: root)
        #expect(envelope?.schemaVersion == 2)
        // Byte-stable canonical re-encode.
        let onDisk = try Data(contentsOf: dest)
        let reencoded = try AutorunContractStore.canonicalEncoder().encode(envelope!)
        #expect(onDisk == reencoded)
    }
}
