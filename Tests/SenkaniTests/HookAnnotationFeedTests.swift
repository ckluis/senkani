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
    /// exit so other tests aren't poisoned.
    private static func withTestFeed(
        windowSeconds: TimeInterval = 0.5,
        mustFixThreshold: Int = 2,
        captured: @escaping (AnnotationRateCapLogRow) -> Void = { _ in },
        body: (HookAnnotationFeed) -> Void
    ) {
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

    // MARK: - Acceptance #1 — denial emits [must-fix]

    @Test("ConfirmationGate deny emits a [must-fix] annotation to the feed")
    func confirmationDenyEmitsMustFixAnnotation() {
        // Stand up a deny resolver. ConfirmationGate writes a chained
        // row, then HookRouter wraps the deny in JSON and emits the
        // annotation. We only care about the annotation here.
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

            // Both are deny responses with the same body. The deny
            // payload is what the agent sees — it MUST be identical.
            #expect(admitted == suppressed,
                    "Suppressing the annotation must not change the deny response")
            // Sanity: both are denies, not passthroughs.
            #expect(admitted != HookRouter.passthroughResponse)
        }
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
