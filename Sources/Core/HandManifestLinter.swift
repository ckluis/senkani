import Foundation

/// One issue surfaced by `HandManifestLinter`. Severity is binary:
/// `error` blocks export, `warning` informs but does not block.
public struct HandManifestIssue: Equatable, Sendable {
    public enum Severity: String, Sendable { case error, warning }

    public var severity: Severity
    public var path: String       // dotted JSON-pointer-like path
    public var message: String

    public init(severity: Severity, path: String, message: String) {
        self.severity = severity
        self.path = path
        self.message = message
    }
}

/// Validates a `HandManifest` against schema v1 invariants. Pure
/// function; no IO. Callers handle file IO and exit codes.
///
/// The lint surface is deliberately small — JSON decoding already
/// caught structural problems by the time we run, so the linter
/// only checks invariants that Codable cannot express:
///   - identity fields non-empty + well-formed
///   - schema version is 1
///   - cadence trigger names are known to HookRouter
///   - guardrails refer only to declared tools
///   - system prompt has at least one phase
public enum HandManifestLinter {
    public static func lint(_ m: HandManifest) -> [HandManifestIssue] {
        var issues: [HandManifestIssue] = []

        if m.schemaVersion != 1 {
            issues.append(.init(
                severity: .error,
                path: "schema_version",
                message: "schema_version must be 1 (got \(m.schemaVersion))"))
        }
        if m.name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(
                severity: .error,
                path: "name",
                message: "name must be non-empty"))
        } else if !isKebabCase(m.name) {
            issues.append(.init(
                severity: .warning,
                path: "name",
                message: "name should be kebab-case (lowercase + dashes)"))
        }
        if m.description.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(
                severity: .error,
                path: "description",
                message: "description must be non-empty"))
        }
        if m.version.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(
                severity: .error,
                path: "version",
                message: "version must be non-empty (semver-ish)"))
        }

        if m.systemPrompt.phases.isEmpty {
            issues.append(.init(
                severity: .error,
                path: "system_prompt.phases",
                message: "system_prompt must have at least one phase"))
        }
        for (idx, phase) in m.systemPrompt.phases.enumerated() {
            if phase.name.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.init(
                    severity: .error,
                    path: "system_prompt.phases[\(idx)].name",
                    message: "phase name must be non-empty"))
            }
            if phase.body.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.init(
                    severity: .error,
                    path: "system_prompt.phases[\(idx)].body",
                    message: "phase body must be non-empty"))
            }
        }

        let toolSet = Set(m.tools)
        for (idx, tool) in m.guardrails.requiresConfirm.enumerated() {
            if !toolSet.contains(tool) {
                issues.append(.init(
                    severity: .error,
                    path: "guardrails.requires_confirm[\(idx)]",
                    message:
                        "requires_confirm references tool '\(tool)' that " +
                        "is not declared in tools[]"))
            }
        }

        for (idx, host) in m.guardrails.egressAllow.enumerated() {
            if host.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append(.init(
                    severity: .error,
                    path: "guardrails.egress_allow[\(idx)]",
                    message: "egress_allow host must be non-empty"))
            }
        }

        for (idx, trig) in m.cadence.triggers.enumerated() {
            if !HandCadence.knownTriggers.contains(trig) {
                issues.append(.init(
                    severity: .error,
                    path: "cadence.triggers[\(idx)]",
                    message:
                        "cadence trigger '\(trig)' is not a known " +
                        "HookRouter event (allowed: " +
                        "\(HandCadence.knownTriggers.sorted().joined(separator: ", ")))"))
            }
        }

        if let sched = m.cadence.schedule,
           sched.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append(.init(
                severity: .error,
                path: "cadence.schedule",
                message: "cadence.schedule, if present, must be non-empty"))
        }

        // V.19a-5 — trust_remote_code lockdown. The HuggingFace
        // `transformers` library treats `trust_remote_code=True` as an
        // arbitrary-code-execution opt-in (the model card's Python is
        // imported and run). Senkani's HandManifest does not host that
        // execution surface today, and this rule locks the gate so a
        // future template or imported profile cannot turn it on through
        // `settings`. The key is matched against three canonical
        // spellings (`trust_remote_code`, `trustRemoteCode`,
        // `TRUST_REMOTE_CODE`); `.bool(true)` is the only flagged value
        // — `.bool(false)` passes (the default-off case) so the rule
        // doesn't break manifests that explicitly opt out.
        let trustRemoteKeys: Set<String> = [
            "trust_remote_code",
            "trustRemoteCode",
            "TRUST_REMOTE_CODE",
        ]
        for key in trustRemoteKeys {
            if case .bool(true) = m.settings[key] {
                issues.append(.init(
                    severity: .error,
                    path: "settings.\(key)",
                    message:
                        "settings.\(key) MUST NOT be true — arbitrary " +
                        "remote-code execution is a hard-blocked " +
                        "capability (V.19a-5 lockdown). Remove the " +
                        "key or set it to false."))
            }
        }

        // T.3b-2 (re-aimed 2026-06-08) — DENY-BY-DEFAULT posture linter.
        //
        // The ratified operator decision (2026-06-05, see
        // `ExecRoutingDecision` / commit ec72a1f) makes user-supplied
        // execution DENY-BY-DEFAULT / fail-CLOSED. No third-party wasm
        // shell is vendored, so the positive wasm guest path is DROPPED
        // indefinitely. A `HandManifest` that declares an execution
        // sandbox other than `.none` therefore opts into a runtime that
        // routes NOWHERE: `ExecRoutingDecision.route(...)` only ever
        // returns `.host` (trusted, no-opt-in) or `.deny` — there is no
        // dispatch that honors `.wasm`, `.proc`, or `.full`. Declaring
        // one misleads the author into believing they constrained
        // execution when nothing reads the field.
        //
        // This rule was originally specced to ENFORCE a `.wasm` opt-in
        // (T.3b-2 positive-wasm linter). It is RE-AIMED to ENFORCE the
        // deny floor instead: warn (do not block — the field is inert,
        // not dangerous) so the author removes the no-op declaration and
        // is not misled. It agrees with the shipped router: the only
        // sandbox value that routes anywhere today is `.none` (which
        // means "no execution-sandbox constraint", the host/deny split is
        // decided by `ExecRoutingDecision` on caller trust, not by this
        // field). See `Sources/Core/ExecRoutingDecision.swift` and
        // `senkani doctor --check-sandbox`.
        if m.sandbox != .none {
            issues.append(.init(
                severity: .warning,
                path: "sandbox",
                message:
                    "sandbox: '\(m.sandbox.rawValue)' routes NOWHERE under " +
                    "deny-by-default (the positive execution-sandbox guest " +
                    "path is dropped; no wasm/proc/full runtime is wired). " +
                    "ExecRoutingDecision honors only host (trusted callers) " +
                    "vs deny (user-supplied) — it never dispatches to a " +
                    "declared sandbox. Set sandbox: 'none'; this declaration " +
                    "is inert and may mislead you into thinking execution is " +
                    "constrained when it is not. Run `senkani doctor " +
                    "--check-sandbox` for the live exec posture."))
        }

        // V.18a-4 — runtime_telemetry.capture=full demands per-field
        // operator review. An empty (or absent) validated_fields map
        // means the operator opted into verbatim capture without
        // declaring which attribute keys they actually reviewed; warn.
        if let rt = m.runtimeTelemetry, rt.capture == .full {
            let v = rt.validatedFields ?? [:]
            if v.isEmpty {
                issues.append(.init(
                    severity: .warning,
                    path: "runtime_telemetry.validated_fields",
                    message:
                        "runtime_telemetry.capture is 'full' but " +
                        "validated_fields is empty — declare each " +
                        "captured attribute key with a per-field " +
                        "validated reason (the `// validated: <reason>` " +
                        "annotation) so the audit trail records " +
                        "operator review"))
            } else {
                for (key, reason) in v where reason.trimmingCharacters(in: .whitespaces).isEmpty {
                    issues.append(.init(
                        severity: .warning,
                        path: "runtime_telemetry.validated_fields[\(key)]",
                        message:
                            "validated_fields['\(key)'] reason is empty " +
                            "— `// validated: <reason>` annotation must " +
                            "name why the field is safe to capture verbatim"))
                }
            }
        }

        return issues
    }

    /// Convenience: load a manifest from JSON bytes and lint it.
    /// Returns either an `error`-severity decoding issue or the
    /// usual lint output.
    public static func lintJSON(_ data: Data) -> [HandManifestIssue] {
        do {
            let m = try JSONDecoder().decode(HandManifest.self, from: data)
            return lint(m)
        } catch {
            return [.init(
                severity: .error,
                path: "(decode)",
                message: "could not decode HandManifest: \(error)")]
        }
    }

    /// True if the lint output blocks export (any error-severity issue).
    public static func hasErrors(_ issues: [HandManifestIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    private static func isKebabCase(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
            && !s.hasPrefix("-")
            && !s.hasSuffix("-")
    }
}
