import Foundation

/// Phase U.5 — `HandManifest` is Senkani's canonical capability-package
/// shape. It supersedes the implicit ad-hoc skill format that Senkani,
/// Claude Code, Cursor, Codex, and OpenCode each invent. A single
/// `HandManifest` JSON document round-trips into per-harness output
/// via `HandManifestExporter`, and is validated by `HandManifestLinter`.
///
/// Schema v1 is **frozen** for required-field reshapes. Future
/// breaking evolutions land as `schemaVersion: 2` with a parallel
/// `HandManifestV2` type; they do not edit this struct. Optional
/// fields with safe defaults (decode as `nil` on older manifests,
/// behave identically to pre-extension code paths) may be added under
/// v1 — `runtimeTelemetry` is the precedent (V.18a-4, 2026-05-22).
public struct HandManifest: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var name: String
    public var description: String
    public var version: String
    public var tools: [String]
    public var settings: [String: HandValue]
    public var metrics: [String]
    public var systemPrompt: HandSystemPrompt
    public var skillMd: String
    public var guardrails: HandGuardrails
    public var cadence: HandCadence
    public var sandbox: HandSandbox
    public var capabilities: [String]
    /// V.18a-4 — opt-in per-source widening for runtime telemetry
    /// capture. Absent on every pre-V.18a-4 manifest; the receiver
    /// treats `nil` as `.metadata` (the safe default).
    public var runtimeTelemetry: HandRuntimeTelemetry?

    public init(
        schemaVersion: Int = 1,
        name: String,
        description: String,
        version: String,
        tools: [String] = [],
        settings: [String: HandValue] = [:],
        metrics: [String] = [],
        systemPrompt: HandSystemPrompt = HandSystemPrompt(phases: []),
        skillMd: String = "",
        guardrails: HandGuardrails = .empty,
        cadence: HandCadence = .empty,
        sandbox: HandSandbox = .none,
        capabilities: [String] = [],
        runtimeTelemetry: HandRuntimeTelemetry? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.version = version
        self.tools = tools
        self.settings = settings
        self.metrics = metrics
        self.systemPrompt = systemPrompt
        self.skillMd = skillMd
        self.guardrails = guardrails
        self.cadence = cadence
        self.sandbox = sandbox
        self.capabilities = capabilities
        self.runtimeTelemetry = runtimeTelemetry
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, description, version, tools, settings, metrics
        case systemPrompt = "system_prompt"
        case skillMd = "skill_md"
        case guardrails, cadence, sandbox, capabilities
        case runtimeTelemetry = "runtime_telemetry"
    }
}

/// V.18a-4 — per-source opt-in widening for runtime telemetry
/// capture. Three modes:
///   - `.metadata` (default): only span/log names, durations, IDs,
///     timestamps, status codes, severities, and non-sensitive
///     attribute keys reach storage. HTTP/RPC bodies, headers, and
///     `process.env.*` attributes are dropped at receive.
///   - `.redactedBodies`: the same metadata plus the otherwise-
///     dropped body/header/env attribute keys, but every captured
///     value is routed through `SecretDetector` before persist.
///   - `.full`: every attribute persisted verbatim. The
///     `validatedFields` map MUST cover every attribute key the
///     operator intends to capture, with a free-text reason
///     (the `// validated: <reason>` annotation). `HandManifestLinter`
///     emits a warning when `capture == .full` and `validatedFields`
///     is nil or empty — the operator skipped the per-field review.
///
/// See `spec/architecture.md#runtime-telemetry-receiver-trust-boundary`
/// (V.18a-3) and `spec/skills.md` (`runtime_telemetry` schema row)
/// for the durable specs.
public struct HandRuntimeTelemetry: Codable, Sendable, Equatable {
    public var capture: CaptureMode
    /// Per-field operator review record, keyed by OTLP attribute key
    /// (e.g. `"http.request.body"`). Value is the free-text reason
    /// the operator captured for the audit trail. Required by lint
    /// when `capture == .full`.
    public var validatedFields: [String: String]?

    public init(
        capture: CaptureMode = .metadata,
        validatedFields: [String: String]? = nil
    ) {
        self.capture = capture
        self.validatedFields = validatedFields
    }

    public enum CaptureMode: String, Codable, Sendable, Equatable {
        case metadata
        case redactedBodies = "redacted_bodies"
        case full
    }

    enum CodingKeys: String, CodingKey {
        case capture
        case validatedFields = "validated_fields"
    }
}

/// Settings value union. Keep the shape small — settings that need
/// richer structure should compose at the harness layer, not bloat
/// the canonical schema.
public enum HandValue: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case int(Int)

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let b = try? c.decode(Bool.self)   { self = .bool(b);   return }
        if let i = try? c.decode(Int.self)    { self = .int(i);    return }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "HandValue must be string, bool, or int")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .bool(let b):   try c.encode(b)
        case .int(let i):    try c.encode(i)
        }
    }
}

/// Multi-phase system prompt. Phases let a manifest layer "preamble"
/// (one-line role), "rules" (must/should), and "examples" (in-context
/// learning) without smashing them into a single blob — exporters
/// emit per-harness section boundaries from this structure.
public struct HandSystemPrompt: Codable, Sendable, Equatable {
    public var phases: [HandPromptPhase]

    public init(phases: [HandPromptPhase]) {
        self.phases = phases
    }
}

public struct HandPromptPhase: Codable, Sendable, Equatable {
    public var name: String   // free-form; "preamble" / "rules" / "examples" by convention
    public var body: String

    public init(name: String, body: String) {
        self.name = name
        self.body = body
    }
}

/// Guardrails block. Three orthogonal axes:
///   - `requiresConfirm` — tools (by name) that must prompt the user
///     before each invocation; bypasses any harness-level "auto" mode.
///   - `egressAllow` — host allowlist applied by EgressProxy when
///     this skill is on the call stack. Unlisted hosts deny.
///   - `secretScope` — does the skill read user secrets, and if so
///     from where (`.session` cleartext only / `.vault` Keychain).
public struct HandGuardrails: Codable, Sendable, Equatable {
    public var requiresConfirm: [String]
    public var egressAllow: [String]
    public var secretScope: SecretScope

    public init(
        requiresConfirm: [String] = [],
        egressAllow: [String] = [],
        secretScope: SecretScope = .none
    ) {
        self.requiresConfirm = requiresConfirm
        self.egressAllow = egressAllow
        self.secretScope = secretScope
    }

    public static let empty = HandGuardrails()

    enum CodingKeys: String, CodingKey {
        case requiresConfirm = "requires_confirm"
        case egressAllow = "egress_allow"
        case secretScope = "secret_scope"
    }
}

public enum SecretScope: String, Codable, Sendable {
    case none, session, vault
}

/// Cadence is when (not how) the skill is invoked. `triggers` is a
/// set of well-known event names; `schedule` is an optional cron
/// expression evaluated by launchd / NaturalLanguageSchedule (U.8).
public struct HandCadence: Codable, Sendable, Equatable {
    public var triggers: [String]
    public var schedule: String?

    public init(triggers: [String] = [], schedule: String? = nil) {
        self.triggers = triggers
        self.schedule = schedule
    }

    public static let empty = HandCadence()

    /// Trigger names recognised by HookRouter today. The linter
    /// rejects unknown values; expand here when HookRouter learns
    /// new event hooks.
    public static let knownTriggers: Set<String> = [
        "session_start", "session_end",
        "pre_tool", "post_tool",
        "pre_compact", "post_compact",
        "schedule",
    ]
}

/// Execution-sandbox surface for hand-manifest-driven tools.
///
/// **Scope clarification (T.3b-1 child (i) — exec-sandbox-naming, 2026-06-05):**
/// `HandSandbox` governs PROCESS EXECUTION (what runtime drives a command),
/// NOT output truncation. The cases are:
///
/// - `.none` — caller-chosen / no constraint; the tool dispatches via its
///   own default (e.g. `Foundation.Process` for `senkani_exec` today).
/// - `.wasm` — execute inside the `WasmtimeSubprocessRuntime` (see
///   `Sources/Core/WasmtimeSubprocessRuntime.swift`). T.3b-1 routing
///   child (iv) lands this as the default for user-supplied scripts;
///   tool-internal callers opt in via this field.
/// - `.proc` — execute via a constrained `Foundation.Process` (e.g.
///   sandbox-exec / seatbelt profile). NOT YET WIRED — reserved.
/// - `.full` — full hand-manifest-declared sandbox (capabilities + IO
///   + filesystem). NOT YET WIRED — reserved.
///
/// For OUTPUT truncation (when large stdout/stderr gets put aside to the
/// `sandboxed_results` DB table), see `SandboxMode` in `OutputSandbox.swift`.
/// The two surfaces share the word "sandbox" but are independent enums
/// with distinct semantics; there is no collision (the original t3b-1
/// P0-#3 collision claim was incorrect — `HandSandbox.wasm` already
/// existed at decompose time and T.3b-2 extends its semantics).
public enum HandSandbox: String, Codable, Sendable, Equatable {
    case none, wasm, proc, full
}
