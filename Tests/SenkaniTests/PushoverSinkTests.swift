import Testing
import Foundation
@testable import Core

/// Coverage for `phase-t6c-pushover-sink` — the AUTONOMOUS sink build.
///
/// Exercises the three ratified gates + default-OFF, all WITHOUT a real
/// token and WITHOUT any network:
///   1. Egress allowlist: the sink reaches ONLY `api.pushover.net`; a
///      non-allowlisted engine DENIES the send before the transport runs.
///   2. Delivery telemetry: a swallowed/failed send records exactly one
///      `delivery_failed` row; a success records a `delivered` heartbeat.
///   3. Body minimization: a planted raw secret / oversized body is ABSENT
///      from the wire; only event-class + ids + a capped template cross.
///   4. Default-OFF / fail-safe: no credentials ⇒ inert, no crash, no
///      transport call, one observable `delivery_failed(unconfigured)` row.
///
/// Tests inject `FakePushoverTransport` + `SpyPushoverDeliveryTelemetry`.
/// Nothing here constructs a real token or touches the real network.
@Suite("T.6c PushoverSink — autonomous sink + 3 gates")
struct PushoverSinkTests {

    // MARK: - GATE (1): egress allowlist is the only egress

    @Test("Gate 1: configured sink sends ONLY to api.pushover.net (the single allowlisted host)")
    func sendsOnlyToPushoverHost() throws {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: .synthetic,
            transport: transport,
            telemetry: telemetry,
            allowEngine: EgressPolicy.pushoverAllowEngine()
        )

        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))

        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].host == "api.pushover.net")
        #expect(transport.sent[0].host == PushoverSink.host)
        // Success heartbeat recorded.
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .delivered)
    }

    @Test("Gate 1: a non-allowlisted egress engine DENIES the send before the transport runs")
    func nonAllowlistedHostIsDenied() throws {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        // Engine that allows some OTHER host but NOT api.pushover.net.
        // api.pushover.net therefore hits default-deny.
        let foreignEngine = EgressRuleEngine(rules: [
            EgressRule(id: "other", pattern: "example.com", mode: .exact, decision: .allow)
        ])
        let sink = PushoverSink(
            credentials: .synthetic,
            transport: transport,
            telemetry: telemetry,
            allowEngine: foreignEngine
        )

        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))

        // The transport was NEVER called — the allowlist gate short-circuited.
        #expect(transport.sent.isEmpty,
                "A non-allowlisted host must be denied BEFORE the transport runs.")
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .deliveryFailed)
        #expect(telemetry.records[0].reason == .egressDenied)
    }

    @Test("Gate 1: an explicit DENY rule for api.pushover.net also blocks the send")
    func explicitDenyBlocks() throws {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        let denyEngine = EgressRuleEngine(rules: [
            EgressRule(id: "deny-pushover", pattern: PushoverSink.host, mode: .exact, decision: .deny)
        ])
        let sink = PushoverSink(
            credentials: .synthetic,
            transport: transport,
            telemetry: telemetry,
            allowEngine: denyEngine
        )

        try sink.notify(.notifyFailure(toolName: "Bash", reason: "boom"))

        #expect(transport.sent.isEmpty)
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].reason == .egressDenied)
    }

    @Test("Gate 1: the default allow engine has exactly one rule — api.pushover.net allow, everything else default-deny")
    func defaultAllowEngineShape() {
        let engine = EgressPolicy.pushoverAllowEngine()
        #expect(engine.rules.count == 1)
        #expect(engine.evaluate(host: "api.pushover.net").decision == .allow)
        #expect(engine.evaluate(host: "api.pushover.net").ruleId == "pushover-sink")
        // Any other host (including a look-alike) is denied on miss.
        #expect(engine.evaluate(host: "pushover.net").decision == .deny)
        #expect(engine.evaluate(host: "evil.example.com").decision == .deny)
        #expect(engine.evaluate(host: "api.pushover.net.evil.com").decision == .deny)
    }

    // MARK: - GATE (2): delivery telemetry — the swallow-site is observable

    @Test("Gate 2: a transport failure records exactly one delivery_failed(transport_error) row and does NOT throw")
    func transportFailureRecordsExactlyOneRow() throws {
        let transport = FakePushoverTransport(shouldThrow: true)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(
            credentials: .synthetic,
            transport: transport,
            telemetry: telemetry
        )

        // MUST NOT throw — the non-blocking contract: a network failure
        // drops the notification, it does not block the agent.
        try sink.notify(.scheduleEnd(scheduleId: "nightly", summary: "done"))

        // The transport WAS attempted (recorded the request) then threw.
        #expect(transport.sent.count == 1)
        // Exactly ONE telemetry row — the swallow is observable, once.
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .deliveryFailed)
        #expect(telemetry.records[0].reason == .transportError)
        #expect(telemetry.records[0].eventClass == "schedule_end")
        #expect(telemetry.records[0].primaryId == "nightly")
    }

    @Test("Gate 2: a successful send records exactly one delivered heartbeat")
    func successRecordsHeartbeat() throws {
        let transport = FakePushoverTransport(shouldThrow: false)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(credentials: .synthetic, transport: transport, telemetry: telemetry)

        try sink.notify(.notifyDone(toolName: "Write", summary: "wrote file"))

        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .delivered)
        #expect(telemetry.records[0].reason == nil)
    }

    @Test("Gate 2: the telemetry row carries NO body/secret — only event-class + scalar id + outcome")
    func telemetryRowIsItselfMinimized() throws {
        let transport = FakePushoverTransport(shouldThrow: true)
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(credentials: .synthetic, transport: transport, telemetry: telemetry)

        let secret = "sk-ant-DEADBEEFDEADBEEFDEADBEEF00112233"
        try sink.notify(.notifyFailure(toolName: "Bash", reason: "leaked \(secret) here"))

        #expect(telemetry.records.count == 1)
        let row = telemetry.records[0]
        // The row has no body field at all; assert the secret appears in
        // NONE of its string-bearing fields.
        #expect(!row.eventClass.contains("DEADBEEF"))
        #expect(!row.primaryId.contains("DEADBEEF"))
        #expect(row.eventClass == "notify_failure")
        #expect(row.primaryId == "Bash")
    }

    // MARK: - GATE (3): body minimization (Cavoukian) at the type level

    @Test("Gate 3: a planted raw secret is ABSENT from the pushed body — SecretDetector redacts it")
    func plantedSecretIsAbsentFromWire() throws {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(credentials: .synthetic, transport: transport, telemetry: telemetry)

        let secret = "sk-ant-SUPERSECRETTOKEN0123456789ABCDEF"
        try sink.notify(.notifyDone(toolName: "Edit", summary: "deployed with \(secret)"))

        #expect(transport.sent.count == 1)
        let msg = transport.sent[0].message
        // The planted secret substring MUST NOT appear anywhere on the wire.
        #expect(!msg.template.contains("SUPERSECRETTOKEN"))
        #expect(!msg.template.contains(secret))
        #expect(!msg.primaryId.contains("SUPERSECRETTOKEN"))
        // Redaction tag present instead.
        #expect(msg.template.contains("REDACTED"))
        // Only event-class + id + capped template cross the boundary.
        #expect(msg.eventClass == "notify_done")
        #expect(msg.primaryId == "Edit")
    }

    @Test("Gate 3: an oversized raw body is hard-capped at maxTemplateLength on the wire")
    func oversizedBodyIsCapped() throws {
        let transport = FakePushoverTransport()
        let sink = PushoverSink(credentials: .synthetic, transport: transport)

        let huge = String(repeating: "A", count: 5000)
        try sink.notify(.scheduleEnd(scheduleId: "big", summary: huge))

        #expect(transport.sent.count == 1)
        let msg = transport.sent[0].message
        // Capped to maxTemplateLength + the single-char ellipsis.
        #expect(msg.template.count <= PushoverMessage.maxTemplateLength + 1)
        #expect(msg.template.hasSuffix("…"))
    }

    @Test("Gate 3: newlines in a raw body are collapsed — no multi-line structure leaks past the boundary")
    func newlinesCollapsed() throws {
        let transport = FakePushoverTransport()
        let sink = PushoverSink(credentials: .synthetic, transport: transport)

        try sink.notify(.notifyFailure(toolName: "T", reason: "line1\nline2\r\nline3\ttabbed"))

        let msg = transport.sent[0].message
        #expect(!msg.template.contains("\n"))
        #expect(!msg.template.contains("\r"))
        #expect(!msg.template.contains("\t"))
    }

    @Test("Gate 3: PushoverMessage is constructible ONLY from a NotifyEvent — no raw-body initializer exists")
    func messageOnlyFromEvent() {
        // Type-level enforcement: the ONLY way to build a message is from an
        // event. This test documents + pins that contract — if someone adds
        // a raw-body init later, the minimization guarantee weakens and this
        // intent comment is the tripwire.
        let msg = PushoverMessage(event: .notifyDone(toolName: "Edit", summary: "ok"))
        #expect(msg.eventClass == "notify_done")
        #expect(msg.primaryId == "Edit")
        #expect(msg.template == "ok")
    }

    @Test("Gate 3: minimize is the single funnel — redacts, collapses, then caps in order")
    func minimizeFunnelOrder() {
        let secret = "sk-ant-AAAAAAAAAAAAAAAAAAAAAAAA1111"
        let out = PushoverMessage.minimize("x\n\(secret)\ty")
        #expect(!out.contains(secret))
        #expect(!out.contains("\n"))
        #expect(!out.contains("\t"))
        #expect(out.contains("REDACTED"))
    }

    // MARK: - DEFAULT-OFF / fail-safe (Allspaw)

    @Test("Default-OFF: no credentials ⇒ sink is inert — no transport call, no crash, no throw")
    func defaultOffIsInert() throws {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        // credentials defaults to nil ⇒ DEFAULT-OFF.
        let sink = PushoverSink(transport: transport, telemetry: telemetry)

        // MUST NOT throw, hang, or crash.
        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))

        // The transport was NEVER called — the sink is genuinely off.
        #expect(transport.sent.isEmpty,
                "Default-OFF sink must never touch the transport.")
        // But the swallow is observable: exactly one unconfigured row.
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .deliveryFailed)
        #expect(telemetry.records[0].reason == .unconfigured)
    }

    @Test("Default-OFF: the all-defaults sink (Null transport, Null telemetry, nil creds) is a safe no-op")
    func allDefaultsAreSafe() throws {
        // Zero-config construction — the production default before any
        // operator seeding. MUST be a silent, crash-free no-op.
        let sink = PushoverSink()
        try sink.notify(.notifyFailure(toolName: "Bash", reason: "anything"))
        try sink.notify(.scheduleEnd(scheduleId: "s", summary: "done"))
        // No assertion target beyond "did not throw / crash" — the Null
        // seams swallow everything. Reaching here is the pass.
        #expect(Bool(true))
    }

    @Test("Default-OFF: an inert sink minimizes the body even though it never sends (no raw secret in the unconfigured telemetry path)")
    func inertSinkStillMinimizes() throws {
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(telemetry: telemetry) // nil creds ⇒ inert

        let secret = "sk-ant-ZZZZZZZZZZZZZZZZZZZZZZZZ9999"
        try sink.notify(.notifyDone(toolName: "leak-\(secret)", summary: secret))

        #expect(telemetry.records.count == 1)
        // Even the unconfigured row's primaryId is scrubbed — the secret
        // never reaches telemetry verbatim.
        #expect(!telemetry.records[0].primaryId.contains("ZZZZ"))
    }

    // MARK: - Integration with the NotificationRouter / fan-out

    @Test("PushoverSink composes as a NotificationSink in the router fan-out (per-sink subscription honoured)")
    func composesInRouterFanout() {
        let transport = FakePushoverTransport()
        let telemetry = SpyPushoverDeliveryTelemetry()
        let sink = PushoverSink(credentials: .synthetic, transport: transport, telemetry: telemetry)

        // Subscribe the pushover sink to notify_failure ONLY.
        let router = NotificationRouter(entries: [
            .init(name: "pushover", sink: sink, events: [.notifyFailure])
        ])

        // notify_done is NOT subscribed ⇒ the sink never sees it.
        router.deliver(.notifyDone(toolName: "Edit", summary: "ok"))
        #expect(transport.sent.isEmpty)

        // notify_failure IS subscribed ⇒ it flows through to the sink.
        router.deliver(.notifyFailure(toolName: "Bash", reason: "denied"))
        #expect(transport.sent.count == 1)
        #expect(transport.sent[0].message.eventClass == "notify_failure")
        #expect(telemetry.records.count == 1)
        #expect(telemetry.records[0].outcome == .delivered)
    }

    @Test("A throwing PushoverSink does not block other sinks in the fan-out (T.6a non-blocking contract)")
    func throwingSinkDoesNotBlockFanout() {
        let throwingTransport = FakePushoverTransport(shouldThrow: true)
        let pushover = PushoverSink(credentials: .synthetic, transport: throwingTransport)
        let otherBridge = SpyLocalNotifierBridge()
        let other = MacOSLocalSink(bridge: otherBridge)

        let router = NotificationRouter(entries: [
            .init(name: "pushover", sink: pushover, events: Set(NotificationRouter.EventKind.allCases)),
            .init(name: "macos", sink: other, events: Set(NotificationRouter.EventKind.allCases)),
        ])

        router.deliver(.notifyFailure(toolName: "Bash", reason: "x"))
        // The macos sink still fired even though pushover's transport threw
        // (and pushover swallowed it internally per its own contract).
        #expect(otherBridge.posted.count == 1)
    }
}
