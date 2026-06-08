import Testing
import Foundation
@testable import Core

/// V.12b — `HookRouter` denial → `DiffAnnotation` pipeline + must-fix
/// rate cap. Acceptance:
///   1. Fixture HookRouter denial emits a `[must-fix]` annotation.
///   2. Rate cap fires on a fixture flood.
///   3. Suppression is non-blocking — agent calls still succeed
///      (deny response is unchanged) unless the underlying denial is
///      itself blocking.
///
/// `.serialized` because `HookAnnotationFeed.shared` and
/// `HookRouter.annotationFeed` are process-wide test seams. Parallel
/// runs would race on subscriber state.
@Suite("V.12b — HookAnnotationFeed + HookRouter denial wiring", .serialized)
struct HookAnnotationFeedTests {

    // MARK: - Fixtures

    private static func makeEvent(
        toolName: String,
        toolInput: [String: Any] = [:],
        sessionId: String? = nil
    ) -> Data {
        var event: [String: Any] = [
            "tool_name": toolName,
            "hook_event_name": "PreToolUse",
        ]
        if !toolInput.isEmpty { event["tool_input"] = toolInput }
        if let sid = sessionId { event["session_id"] = sid }
        return try! JSONSerialization.data(withJSONObject: event)
    }

    private static func denyResolver(
        reason: String = "T.6a fixture deny"
    ) -> ConfirmationGate.PolicyResolver {
        return { _, _ in (.deny, .operator, reason) }
    }

    /// Run a closure with `HookRouter.annotationFeed` swapped out for
    /// a fresh feed (short window, no DB sink). Restores defaults on
    /// exit so other tests aren't poisoned. Holds `HookSeamLock` so
    /// peer suites running through `HookRouter.handle` cannot read
    /// the test's private feed (cross-suite race fix).
    private static func withTestFeed(
        windowSeconds: TimeInterval = 0.5,
        mustFixThreshold: Int = 2,
        captured: @escaping (AnnotationRateCapLogRow) -> Void = { _ in },
        body: (HookAnnotationFeed) -> Void
    ) {
        HookSeamLock.withLock {
            let feed = HookAnnotationFeed(
                windowSeconds: windowSeconds,
                mustFixThreshold: mustFixThreshold,
                rateCapSink: captured
            )
            let priorFeed = HookRouter.annotationFeed
            HookRouter.annotationFeed = feed
            defer { HookRouter.annotationFeed = priorFeed }
            body(feed)
        }
    }

    // MARK: - Acceptance #1 — denial emits [must-fix]

    @Test("ConfirmationGate deny emits a [must-fix] annotation to the feed")
    func confirmationDenyEmitsMustFixAnnotation() {
        // Stand up a deny resolver. ConfirmationGate writes a chained
        // row, then HookRouter wraps the deny in JSON and emits the
        // annotation. We only care about the annotation here.
        // HookSeamLock held by the inner withTestFeed; this outer
        // withLock pairs the resolver swap with the same lock so peer
        // suites can't observe the deny resolver mid-test.
        HookSeamLock.shared.lock()
        defer { HookSeamLock.shared.unlock() }
        let priorResolver = ConfirmationGate.resolver
        ConfirmationGate.resolver = Self.denyResolver(reason: "fixture")
        defer { ConfirmationGate.resolver = priorResolver }

        Self.withTestFeed { feed in
            var captured: [HookAnnotation] = []
            feed.subscribe { captured.append($0) }

            // Edit is write-tagged in the default catalog → goes through
            // the ConfirmationGate; resolver returns .deny → annotation.
            let event = Self.makeEvent(
                toolName: "Edit",
                toolInput: ["file_path": "/tmp/fixture.swift"],
                sessionId: "sess-fixture"
            )
            _ = HookRouter.handle(eventJSON: event)

            #expect(captured.count == 1, "Exactly one annotation should fire on a single deny")
            guard let ann = captured.first else { return }
            #expect(ann.severity == .mustFix, "Deny must be tagged must-fix")
            #expect(ann.toolName == "Edit")
            #expect(ann.filePath == "/tmp/fixture.swift",
                    "filePath must propagate so the pane can match leftPath/rightPath")
            #expect(ann.body.contains("fixture") || ann.body.contains("Edit"),
                    "Body should carry the deny context the agent sees")
        }
    }

    // MARK: - Acceptance #2 — rate cap fires

    @Test("Must-fix rate cap suppresses annotations past the per-window threshold")
    func mustFixRateCapSuppressesPastThreshold() {
        Self.withTestFeed(windowSeconds: 60, mustFixThreshold: 2) { feed in
            var admittedCount = 0
            feed.subscribe { _ in admittedCount += 1 }

            let now = Date()
            let outcome1 = feed.record(.fixture(severity: .mustFix), now: now)
            let outcome2 = feed.record(.fixture(severity: .mustFix), now: now.addingTimeInterval(1))
            let outcome3 = feed.record(.fixture(severity: .mustFix), now: now.addingTimeInterval(2))
            let outcome4 = feed.record(.fixture(severity: .mustFix), now: now.addingTimeInterval(3))

            #expect(outcome1 == .admitted)
            #expect(outcome2 == .admitted)
            #expect(outcome3 == .suppressed, "Third must-fix in same window must be suppressed")
            #expect(outcome4 == .suppressed)
            #expect(admittedCount == 2, "Subscribers see admitted only — suppressed are silent")
        }
    }

    // MARK: - Acceptance #3 — suppression is non-blocking

    @Test("Deny response JSON is unchanged whether the annotation is admitted or suppressed")
    func denyResponseUnaffectedByRateCap() {
        HookSeamLock.shared.lock()
        defer { HookSeamLock.shared.unlock() }
        let priorResolver = ConfirmationGate.resolver
        ConfirmationGate.resolver = Self.denyResolver(reason: "fixture-noblock")
        defer { ConfirmationGate.resolver = priorResolver }

        // Fill the rate-cap budget so the second deny's annotation is
        // suppressed, then capture and compare the deny JSON returned
        // for both calls. The deny path must not depend on whether
        // the annotation was admitted.
        Self.withTestFeed(windowSeconds: 60, mustFixThreshold: 1) { _ in
            let event = Self.makeEvent(
                toolName: "Edit",
                toolInput: ["file_path": "/tmp/non-blocking-fixture.swift"]
            )
            let admitted = HookRouter.handle(eventJSON: event)
            let suppressed = HookRouter.handle(eventJSON: event)

            // Both are deny responses with the same semantic body. The
            // deny payload is what the agent sees — it MUST be
            // equivalent, but compare PARSED JSON, not raw bytes:
            // `JSONSerialization.data(withJSONObject:)` doesn't promise
            // deterministic key order, and the deny response inner dict
            // has 3 keys (6 possible orderings). Two sequential calls
            // can serialize them differently under parallel-runner CPU
            // pressure even when the semantic content is identical
            // (158 == 158 bytes but not byte-for-byte equal). See
            // `hookannotationfeed-deny-json-byte-equality-flake-2026-05-04`.
            let admittedJSON = try? JSONSerialization.jsonObject(with: admitted) as? NSDictionary
            let suppressedJSON = try? JSONSerialization.jsonObject(with: suppressed) as? NSDictionary
            #expect(admittedJSON != nil, "admitted response must be valid JSON")
            #expect(suppressedJSON != nil, "suppressed response must be valid JSON")
            #expect(admittedJSON == suppressedJSON,
                    "Suppressing the annotation must not change the deny response (parsed-JSON equality)")
            // Sanity: both are denies, not passthroughs.
            #expect(admitted != HookRouter.passthroughResponse)
        }
    }

    // MARK: - V.3a — admitted annotation → canonical agent_trace_event row

    private static func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-hookann-trace-\(UUID().uuidString)/senkani.db"
        return (SessionDatabase(path: path), path)
    }

    private static func cleanupDB(path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Swap `HookRouter.annotationTraceDatabase` to a temp DB for the body,
    /// restoring the prior value on exit. Held under the same withTestFeed
    /// HookSeamLock so peer suites running `HookRouter.handle` can't observe
    /// the test's private trace DB.
    @Test("V.3a — admitted ConfirmationGate deny writes exactly one agent_trace_event row with matching pane + tool")
    func admittedAnnotationWritesCanonicalTraceRow() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(path: dbPath) }

        HookSeamLock.shared.lock()
        defer { HookSeamLock.shared.unlock() }
        let priorResolver = ConfirmationGate.resolver
        ConfirmationGate.resolver = Self.denyResolver(reason: "v3a-fixture")
        defer { ConfirmationGate.resolver = priorResolver }
        let priorTraceDB = HookRouter.annotationTraceDatabase
        HookRouter.annotationTraceDatabase = db
        defer { HookRouter.annotationTraceDatabase = priorTraceDB }

        Self.withTestFeed { _ in
            #expect(db.agentTraceEventCount() == 0, "baseline: no trace rows")
            let event = Self.makeEvent(
                toolName: "Edit",
                toolInput: ["file_path": "/tmp/v3a.swift"],
                sessionId: "sess-v3a"
            )
            _ = HookRouter.handle(eventJSON: event)

            #expect(db.agentTraceEventCount() == 1,
                    "one admitted annotation → exactly one canonical row")

            // The derived key isn't known to the test, but the single row's
            // dimensions must match: pane = sessionId, tool_call_id = tool.
            let rows = db.agentTraceRowsInWindow(project: nil, since: nil)
            #expect(rows.count == 1)
            guard let row = rows.first else { return }
            #expect(row.pane == "sess-v3a", "pane must carry the annotation's sessionId")
            #expect(row.sessionId == "sess-v3a")
            #expect(row.toolCallId == "Edit", "tool name must propagate into the row")
            #expect(row.result == .denied, "must-fix denial maps to .denied")
        }
    }

    @Test("V.3a — a suppressed (rate-capped) annotation writes NO extra agent_trace_event row")
    func suppressedAnnotationWritesNoTraceRow() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(path: dbPath) }

        HookSeamLock.shared.lock()
        defer { HookSeamLock.shared.unlock() }
        let priorResolver = ConfirmationGate.resolver
        ConfirmationGate.resolver = Self.denyResolver(reason: "v3a-suppress")
        defer { ConfirmationGate.resolver = priorResolver }
        let priorTraceDB = HookRouter.annotationTraceDatabase
        HookRouter.annotationTraceDatabase = db
        defer { HookRouter.annotationTraceDatabase = priorTraceDB }

        // threshold 1 → the FIRST must-fix is admitted (1 row), the SECOND
        // is suppressed (no extra row). Same window (60s) so the second
        // never rolls.
        Self.withTestFeed(windowSeconds: 60, mustFixThreshold: 1) { _ in
            let event = Self.makeEvent(
                toolName: "Edit",
                toolInput: ["file_path": "/tmp/v3a-suppress.swift"],
                sessionId: "sess-suppress"
            )
            _ = HookRouter.handle(eventJSON: event)   // admitted → 1 row
            #expect(db.agentTraceEventCount() == 1, "first admitted → one row")

            _ = HookRouter.handle(eventJSON: event)   // suppressed → no row
            #expect(db.agentTraceEventCount() == 1,
                    "suppressed annotation must NOT add a canonical row")
        }
    }

    @Test("V.3a — re-emitting the SAME admitted annotation dedups via derived idempotency_key")
    func admittedAnnotationDedupsOnRetry() {
        let (db, dbPath) = Self.makeTempDB()
        defer { Self.cleanupDB(path: dbPath) }

        let priorTraceDB = HookRouter.annotationTraceDatabase
        HookRouter.annotationTraceDatabase = db
        defer { HookRouter.annotationTraceDatabase = priorTraceDB }

        // Drive the extracted derivation directly with a STABLE annotation
        // (fixed id + createdAt) so the derived key is identical across
        // calls. ON CONFLICT DO NOTHING then absorbs the retry.
        let ann = HookAnnotation(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            severity: .mustFix,
            body: "dedup body",
            toolName: "Write",
            filePath: "/tmp/dedup.swift",
            sessionId: "sess-dedup",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        HookRouter.recordAdmittedAnnotationTrace(ann)
        HookRouter.recordAdmittedAnnotationTrace(ann)
        #expect(db.agentTraceEventCount() == 1,
                "two writes of the same annotation land exactly one row (derived-key dedup)")
    }

    // MARK: - Acceptance #2 (extended) — rate-cap log row on rollover

    @Test("Window rollover writes one rate-cap log row carrying the suppressed count")
    func rolloverWritesRateCapLogRow() {
        var rows: [AnnotationRateCapLogRow] = []
        Self.withTestFeed(
            windowSeconds: 60,
            mustFixThreshold: 1,
            captured: { rows.append($0) }
        ) { feed in
            let t0 = Date()
            // 1 admitted + 2 suppressed in window 1.
            _ = feed.record(.fixture(severity: .mustFix), now: t0)
            _ = feed.record(.fixture(severity: .mustFix), now: t0.addingTimeInterval(1))
            _ = feed.record(.fixture(severity: .mustFix), now: t0.addingTimeInterval(2))
            #expect(rows.isEmpty, "Rate-cap row is not written until the window closes")

            // Advance past windowSeconds — the next record() rolls.
            _ = feed.record(.fixture(severity: .suggestion), now: t0.addingTimeInterval(120))
            #expect(rows.count == 1, "Window roll with prior suppression writes exactly one row")
            guard let row = rows.first else { return }
            #expect(row.severity == DiffAnnotationSeverity.mustFix.rawValue)
            #expect(row.suppressedCount == 2)
            #expect(row.threshold == 1)
        }
    }
}

private extension HookAnnotation {
    /// Test helper — fresh annotation with all the boring fields
    /// filled in so callers only specify what they actually assert.
    static func fixture(
        severity: DiffAnnotationSeverity,
        toolName: String = "Edit",
        body: String = "fixture body",
        filePath: String? = nil
    ) -> HookAnnotation {
        return HookAnnotation(
            severity: severity,
            body: body,
            toolName: toolName,
            filePath: filePath,
            sessionId: nil
        )
    }
}
