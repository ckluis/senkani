import Foundation

/// Phase T.6c — `PushoverSink` (autonomous SINK build).
///
/// A `NotificationSink` that fans a `NotifyEvent` out to Pushover
/// (https://pushover.net) over HTTPS. This file is the AUTONOMOUS,
/// CI-testable portion of T.6c: the sink, its three security gates, and an
/// injectable transport. It compiles and tests WITHOUT a real app token,
/// user key, or any network access.
///
/// The OPERATOR REMAINDER (NOT built here, and deliberately so) is:
///   - seeding the real Pushover app token + user key into the macOS
///     Keychain via `senkani doctor --seed-pushover-key`, and
///   - proving live delivery against the real `api.pushover.net`.
/// Neither a real token nor the real network is ever required to build or
/// test this sink.
///
/// ## The three ratified gates (operator decision 2026-06-08)
///
/// **(1) Egress allowlist — the ONLY host the sink may reach.**
/// `PushoverSink.host` is the single constant `api.pushover.net`. Before a
/// send the sink consults an injected `EgressRuleEngine` (the existing
/// egress mechanism). A request to any non-allowlisted host is DENIED
/// before the transport is ever called — there is no code path that lets
/// the sink reach a different host. `EgressPolicy.pushoverAllowEngine()`
/// provides the single allow rule; everything else stays deny-on-miss.
///
/// **(2) Delivery telemetry at the fan-out — a swallowed send is
/// observable (Majors).** When a send fails, is denied by the allowlist,
/// or the sink is inert, the swallow-site records a `delivery_failed` (and
/// the success path a `delivered` heartbeat) row through an injected
/// `PushoverDeliveryTelemetry`. A silently-dropped notification is no
/// longer invisible — it leaves exactly one telemetry row.
///
/// **(3) Body minimization (Cavoukian) — enforced at the type level.**
/// `PushoverMessage` can ONLY be constructed via `init(event:)`, which
/// derives an event-class string, scalar ids, and a LENGTH-CAPPED template
/// from the `NotifyEvent`. There is no initializer that accepts a raw body,
/// secret, or free-form text. Raw event summaries/reasons NEVER cross the
/// host boundary verbatim — they are run through `SecretDetector` and
/// truncated to `PushoverMessage.maxTemplateLength`.
///
/// ## Default-OFF / fail-safe (Allspaw)
/// The sink is constructed with an optional `PushoverCredentialsRef`. When
/// `nil` (the default — no token configured) the sink is INERT: every
/// `notify(_:)` records a `delivery_failed` "unconfigured" telemetry row
/// and returns without touching the transport or the network. It never
/// crashes, never blocks, and never requires a token to exist.
public struct PushoverSink: NotificationSink, Sendable {

    /// The ONE host this sink may ever reach. Compile-time constant — there
    /// is no setter and no code path that targets a different host.
    public static let host = "api.pushover.net"

    /// The Pushover message-push path. Used to shape the request; the host
    /// is the security boundary, the path is informational.
    public static let path = "/1/messages.json"

    private let credentials: PushoverCredentialsRef?
    private let transport: PushoverTransport
    private let telemetry: PushoverDeliveryTelemetry
    private let allowEngine: EgressRuleEngine

    /// Build a PushoverSink.
    ///
    /// - Parameters:
    ///   - credentials: an opaque reference to where the operator-seeded
    ///     token + user key live (Keychain). `nil` ⇒ DEFAULT-OFF: the sink
    ///     is inert and never sends. Production passes a non-nil ref ONLY
    ///     after `senkani doctor --seed-pushover-key` has run; tests pass a
    ///     synthetic ref to exercise the wired path WITHOUT a real token.
    ///   - transport: the HTTP transport seam. Defaults to
    ///     `NullPushoverTransport` (never sends). Tests inject
    ///     `FakePushoverTransport`; production injects a real
    ///     allowlist-checked transport — neither is required to compile.
    ///   - telemetry: the delivery-telemetry seam. Defaults to
    ///     `NullPushoverDeliveryTelemetry`.
    ///   - allowEngine: the egress rule engine the sink consults before a
    ///     send. Defaults to the single-rule Pushover allow engine
    ///     (`EgressPolicy.pushoverAllowEngine()`).
    public init(
        credentials: PushoverCredentialsRef? = nil,
        transport: PushoverTransport = NullPushoverTransport(),
        telemetry: PushoverDeliveryTelemetry = NullPushoverDeliveryTelemetry(),
        allowEngine: EgressRuleEngine = EgressPolicy.pushoverAllowEngine()
    ) {
        self.credentials = credentials
        self.transport = transport
        self.telemetry = telemetry
        self.allowEngine = allowEngine
    }

    public func notify(_ event: NotifyEvent) throws {
        // GATE (3) — body minimization happens at construction time. There
        // is no other way to build a message, so no raw body can leak.
        let message = PushoverMessage(event: event)

        // DEFAULT-OFF / fail-safe (Allspaw): no seeded token ⇒ the sink is
        // inert. Record an observable telemetry row and return. Never
        // touches the transport or the network; never throws past here.
        guard credentials != nil else {
            telemetry.record(
                PushoverDeliveryRecord(
                    outcome: .deliveryFailed,
                    reason: .unconfigured,
                    eventClass: message.eventClass,
                    primaryId: message.primaryId
                )
            )
            return
        }

        // GATE (1) — egress allowlist. The sink may ONLY reach
        // `PushoverSink.host`. Evaluate it against the injected engine; a
        // deny (or default-deny) short-circuits BEFORE the transport runs.
        let evaluation = allowEngine.evaluate(host: Self.host)
        guard evaluation.decision == .allow else {
            telemetry.record(
                PushoverDeliveryRecord(
                    outcome: .deliveryFailed,
                    reason: .egressDenied,
                    eventClass: message.eventClass,
                    primaryId: message.primaryId
                )
            )
            return
        }

        // Attempt the send through the injected transport. GATE (2) — the
        // swallow-site is instrumented: success records a `delivered`
        // heartbeat, any failure records exactly one `delivery_failed` row.
        // A throw NEVER propagates past the sink (the T.6a non-blocking
        // contract): the fan-out must not stall the agent.
        do {
            try transport.send(
                PushoverRequest(host: Self.host, path: Self.path, message: message)
            )
            telemetry.record(
                PushoverDeliveryRecord(
                    outcome: .delivered,
                    reason: nil,
                    eventClass: message.eventClass,
                    primaryId: message.primaryId
                )
            )
        } catch {
            telemetry.record(
                PushoverDeliveryRecord(
                    outcome: .deliveryFailed,
                    reason: .transportError,
                    eventClass: message.eventClass,
                    primaryId: message.primaryId
                )
            )
            // Swallow per the non-blocking contract — a network failure
            // drops the notification, it does NOT block the agent.
        }
    }
}

// MARK: - Credentials reference (opaque; NEVER carries a real token here)

/// An opaque marker that the operator HAS seeded Pushover credentials.
///
/// SECURITY (Schneier): this type carries NO secret material in the
/// autonomous build. It is a presence flag — its existence means "a token
/// is expected to be retrievable at send time" (from the Keychain, via the
/// real transport the operator wires later). The real token is fetched by
/// the production transport at the moment of sending and NEVER stored on
/// this value, NEVER logged, and NEVER placed in a `PushoverMessage`.
///
/// In tests we construct a `PushoverCredentialsRef.synthetic` to exercise
/// the wired path without any real token. In production the operator
/// remainder (`senkani doctor --seed-pushover-key`) seeds the Keychain and
/// the real transport reads from it — none of that lives in this file.
public struct PushoverCredentialsRef: Sendable, Equatable {
    /// The Keychain account/service the real transport will read at send
    /// time. Defaults to the senkani Pushover slot. NOT a secret.
    public let keychainAccount: String

    public init(keychainAccount: String = "senkani.pushover") {
        self.keychainAccount = keychainAccount
    }

    /// Test-only marker: "pretend a token is seeded" WITHOUT any real
    /// secret. Lets CI exercise the configured (non-inert) path.
    public static let synthetic = PushoverCredentialsRef(keychainAccount: "synthetic.test.no.secret")
}

public extension PushoverCredentialsRef {
    /// T.6c — the canonical vault KEY NAME under which `senkani doctor
    /// --seed-pushover-key` stores the Pushover credential, and from
    /// which the real Keychain-reading transport (T.6c sibling carve)
    /// reads it at send time. This is the NAME of the slot — never a
    /// secret. Matches the default `keychainAccount` so a
    /// default-initialized ref points at the seeded slot.
    static let vaultKey = "senkani.pushover"

    /// T.6c — the `CredentialVault` scope the seeded credential lives in.
    static let vaultScope = CredentialVault.defaultScope
}

// MARK: - GATE (3): the minimized message (body minimization at the type level)

/// The minimized push payload. Construction is the enforcement point:
/// `init(event:)` is the ONLY initializer, and it derives event-class +
/// scalar ids + a length-capped, secret-scrubbed template. There is
/// deliberately NO initializer that accepts a raw body, secret, or
/// arbitrary text — so a caller CANNOT smuggle a full event body or a
/// secret into a push, even by accident (Cavoukian: privacy by design).
public struct PushoverMessage: Sendable, Equatable {

    /// Hard cap on the length-bounded template that crosses the host
    /// boundary. Pushover itself caps messages at 1024 chars; we cap far
    /// tighter — the push is a *pointer*, not a payload.
    public static let maxTemplateLength = 120

    /// Stable event-class string (`notify_done` / `notify_failure` /
    /// `schedule_end`). Mirrors `StdoutSink`/`NotificationRouter` wire keys.
    public let eventClass: String

    /// The scalar id that names this event (the tool name for notify
    /// events, the schedule id for schedule_end). An identifier, not a body.
    public let primaryId: String

    /// A short, length-capped, secret-scrubbed human template. NEVER the
    /// raw summary/reason verbatim if it is long or contains a secret.
    public let template: String

    /// The ONLY initializer. Derives every field from the event and
    /// enforces minimization. Private state is impossible to set otherwise.
    public init(event: NotifyEvent) {
        switch event {
        case .notifyDone(let tool, let summary):
            self.eventClass = "notify_done"
            self.primaryId = Self.scrubId(tool)
            self.template = Self.minimize(summary)
        case .notifyFailure(let tool, let reason):
            self.eventClass = "notify_failure"
            self.primaryId = Self.scrubId(tool)
            self.template = Self.minimize(reason)
        case .scheduleEnd(let scheduleId, let summary):
            self.eventClass = "schedule_end"
            self.primaryId = Self.scrubId(scheduleId)
            self.template = Self.minimize(summary)
        }
    }

    /// Minimize a free-form string for the wire: redact any detected
    /// secret, collapse newlines, then hard-truncate to
    /// `maxTemplateLength` (appending an ellipsis when truncated). This is
    /// the single funnel every body-bearing field passes through.
    static func minimize(_ raw: String) -> String {
        // 1. Redact secrets (SecretDetector replaces matches with a tag).
        let redacted = SecretDetector.scan(raw).redacted
        // 2. Collapse CR/LF + tabs to single spaces so a multi-line body
        //    can't carry structure (or hide content past a newline) onto
        //    the wire.
        let oneLine = redacted
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        // 3. Hard length cap. The push is a pointer; the operator opens
        //    senkani for detail.
        if oneLine.count <= maxTemplateLength {
            return oneLine
        }
        let endIdx = oneLine.index(oneLine.startIndex, offsetBy: maxTemplateLength)
        return String(oneLine[..<endIdx]) + "…"
    }

    /// Scrub + cap an id. Ids are short identifiers, not bodies, but an
    /// adversarial caller could pass a giant "tool name"; redact secrets
    /// and cap to the same bound so the id field is never an exfil channel.
    static func scrubId(_ raw: String) -> String {
        minimize(raw)
    }
}

// MARK: - Request shape (host is fixed; carries only the minimized message)

/// The request the transport receives. The host is fixed to
/// `PushoverSink.host` by the sink (the only construction site); the body
/// is a `PushoverMessage` (already minimized). The transport turns this
/// into the actual HTTP form-POST at send time, pulling the real token
/// from the Keychain — the token is NEVER on this value.
public struct PushoverRequest: Sendable, Equatable {
    public let host: String
    public let path: String
    public let message: PushoverMessage

    public init(host: String, path: String, message: PushoverMessage) {
        self.host = host
        self.path = path
        self.message = message
    }
}

// MARK: - GATE (1) helper: the single Pushover allow rule

public extension EgressPolicy {
    /// The single egress allow rule for `api.pushover.net` — the ONLY host
    /// the PushoverSink may reach. Everything else stays deny-on-miss
    /// (`EgressEvaluation.defaultDeny`). Mirrors the ServeAllow pattern:
    /// senkani does NOT auto-add this to the operator's
    /// `egress-policy.json`; the sink consults this engine directly so the
    /// allowlist gate is enforced even before the operator customizes
    /// their global policy.
    static func pushoverAllowRule() -> EgressRule {
        EgressRule(
            id: "pushover-sink",
            pattern: PushoverSink.host,
            mode: .exact,
            decision: .allow
        )
    }

    /// An `EgressRuleEngine` whose only rule is the Pushover allow rule.
    /// This is the sink's default `allowEngine`: `api.pushover.net` →
    /// allow, every other host → default-deny.
    static func pushoverAllowEngine() -> EgressRuleEngine {
        EgressRuleEngine(rules: [pushoverAllowRule()])
    }
}

// MARK: - GATE (2): delivery telemetry seam

/// Outcome of one delivery attempt at the fan-out swallow-site.
public enum PushoverDeliveryOutcome: String, Sendable, Equatable {
    /// Send succeeded (heartbeat).
    case delivered
    /// Send was dropped/swallowed — observable so it isn't silent.
    case deliveryFailed = "delivery_failed"
}

/// Why a `delivery_failed` row was recorded. Lets an operator distinguish
/// "no token seeded yet" from "the network is down" from "the allowlist
/// blocked an unexpected host".
public enum PushoverDeliveryFailReason: String, Sendable, Equatable {
    /// DEFAULT-OFF: no credentials seeded — the sink is inert.
    case unconfigured
    /// GATE (1): the host was not on the egress allowlist.
    case egressDenied = "egress_denied"
    /// The transport threw (network failure, non-2xx, etc.).
    case transportError = "transport_error"
}

/// One telemetry row emitted at the fan-out. Carries ONLY the event-class +
/// the scalar id + the outcome/reason — NEVER the body or any secret
/// (Cavoukian applies to the telemetry row too, not just the push).
public struct PushoverDeliveryRecord: Sendable, Equatable {
    public let outcome: PushoverDeliveryOutcome
    public let reason: PushoverDeliveryFailReason?
    public let eventClass: String
    public let primaryId: String

    public init(
        outcome: PushoverDeliveryOutcome,
        reason: PushoverDeliveryFailReason?,
        eventClass: String,
        primaryId: String
    ) {
        self.outcome = outcome
        self.reason = reason
        self.eventClass = eventClass
        self.primaryId = primaryId
    }
}

/// The telemetry seam. Production wires a DB-backed recorder (operator
/// remainder / a later round); the sink only needs "record this row".
public protocol PushoverDeliveryTelemetry: Sendable {
    /// Record one delivery row. MUST be best-effort + non-throwing — a
    /// telemetry failure must not block the agent.
    func record(_ record: PushoverDeliveryRecord)
}

/// No-op telemetry. Default when nothing is wired (CLI / headless).
public struct NullPushoverDeliveryTelemetry: PushoverDeliveryTelemetry {
    public init() {}
    public func record(_ record: PushoverDeliveryRecord) {
        // intentionally empty — null recorder
    }
}

/// Test recorder. Captures every row in order. Thread-safe via `NSLock`.
public final class SpyPushoverDeliveryTelemetry: PushoverDeliveryTelemetry, @unchecked Sendable {
    private let lock = NSLock()
    private var _records: [PushoverDeliveryRecord] = []

    public init() {}

    public var records: [PushoverDeliveryRecord] {
        lock.lock()
        defer { lock.unlock() }
        return _records
    }

    public func record(_ record: PushoverDeliveryRecord) {
        lock.lock()
        _records.append(record)
        lock.unlock()
    }

    public func reset() {
        lock.lock()
        _records.removeAll()
        lock.unlock()
    }
}

// MARK: - Transport seam (NO real network in the autonomous build)

/// The HTTP transport seam. The sink hands a `PushoverRequest` (host fixed,
/// body minimized) to a transport; the transport performs the actual send.
///
/// In the autonomous build the default is `NullPushoverTransport` (never
/// sends) and tests inject `FakePushoverTransport` (records the request,
/// optionally throws). The REAL transport — which reads the Keychain token
/// and POSTs to `api.pushover.net` — is the operator remainder and is NOT
/// implemented here.
public protocol PushoverTransport: Sendable {
    /// Perform one send. Throws on any failure (the sink catches + records
    /// `delivery_failed` and swallows per the non-blocking contract).
    func send(_ request: PushoverRequest) throws
}

/// No-op transport: never sends, never throws. Default seam so the sink
/// compiles + runs with zero network and zero token. A sink wired with
/// this transport but a non-nil credentials ref records a `delivered`
/// heartbeat without any traffic (used to prove the wiring in CI).
public struct NullPushoverTransport: PushoverTransport {
    public init() {}
    public func send(_ request: PushoverRequest) throws {
        // intentionally empty — no network in the autonomous build
    }
}

/// Test transport: records every request it is handed, and optionally
/// throws to exercise the `delivery_failed` swallow-site. NEVER touches the
/// network.
public final class FakePushoverTransport: PushoverTransport, @unchecked Sendable {
    public enum FakeError: Error, Equatable { case injected }

    private let lock = NSLock()
    private var _sent: [PushoverRequest] = []
    /// When true, every `send` records the request THEN throws.
    public var shouldThrow: Bool

    public init(shouldThrow: Bool = false) {
        self.shouldThrow = shouldThrow
    }

    public var sent: [PushoverRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _sent
    }

    public func send(_ request: PushoverRequest) throws {
        lock.lock()
        _sent.append(request)
        let willThrow = shouldThrow
        lock.unlock()
        if willThrow { throw FakeError.injected }
    }

    public func reset() {
        lock.lock()
        _sent.removeAll()
        lock.unlock()
    }
}
