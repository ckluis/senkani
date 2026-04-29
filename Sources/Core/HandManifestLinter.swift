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
