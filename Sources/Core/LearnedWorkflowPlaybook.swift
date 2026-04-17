import Foundation

// MARK: - LearnedWorkflowPlaybook
//
// Phase H+2c — multi-step recipe detected from repeating tool-call
// sequences. Unlike filter rules (reactive guardrails) or context docs
// (passive priming), playbooks are INVOCABLE — the agent calls a
// playbook by name via `senkani_session action:"playbook"` (future
// wiring; H+2c ships the artifact + generator only).
//
// Namespace isolation (Schneier): on-disk storage lives under
// `.senkani/playbooks/learned/<slug>.md`. Shipped skills live under
// `.senkani/skills/`. A learned playbook CAN NOT shadow a shipped
// skill by construction — different directory root. SkillScanner
// picks up shipped skills; learned playbooks surface via
// `senkani learn status --type workflow` only for this round.
//
// A playbook is a sequence of steps. Each step is a tool call (or a
// manual instruction). The body markdown renders the sequence
// human-readably. Both the structured steps and the rendered body
// pass through safety sanitizers.

public struct LearnedWorkflowStep: Codable, Sendable, Equatable {
    /// MCP tool name for this step. Sanitized identical to
    /// `LearnedInstructionPatch.sanitizeToolName`.
    public let toolName: String
    /// One-line example invocation (e.g., "senkani_outline file:Foo.swift").
    public var example: String

    public init(toolName: String, example: String) {
        self.toolName = LearnedInstructionPatch.sanitizeToolName(toolName)
        self.example = LearnedInstructionPatch.sanitizeHint(example)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.toolName = LearnedInstructionPatch.sanitizeToolName(
            try c.decode(String.self, forKey: .toolName))
        self.example = LearnedInstructionPatch.sanitizeHint(
            try c.decode(String.self, forKey: .example))
    }
}

public struct LearnedWorkflowPlaybook: Codable, Sendable, Equatable {
    public let id: String
    /// Filesystem-safe slug for `.senkani/playbooks/learned/<title>.md`.
    public let title: String
    /// Description (markdown). Capped + SecretDetector-scanned.
    public var description: String
    public var steps: [LearnedWorkflowStep]
    public var sources: [String]
    public let confidence: Double
    public var status: LearnedRuleStatus
    public let createdAt: Date
    public var lastSeenAt: Date
    public var recurrenceCount: Int
    public var sessionCount: Int

    public static let maxDescriptionBytes: Int = 2048
    public static let maxSteps: Int = 12
    public static let maxTitleChars: Int = 64

    public init(
        id: String,
        title: String,
        description: String,
        steps: [LearnedWorkflowStep],
        sources: [String],
        confidence: Double,
        status: LearnedRuleStatus = .recurring,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        recurrenceCount: Int = 1,
        sessionCount: Int = 0
    ) {
        self.id = id
        self.title = LearnedContextDoc.sanitizeTitle(title)
        self.description = Self.sanitizeDescription(description)
        self.steps = Array(steps.prefix(Self.maxSteps))
        self.sources = sources
        self.confidence = max(0, min(1, confidence))
        self.status = status
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt ?? createdAt
        self.recurrenceCount = max(1, recurrenceCount)
        self.sessionCount = max(0, sessionCount)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = LearnedContextDoc.sanitizeTitle(try c.decode(String.self, forKey: .title))
        self.description = Self.sanitizeDescription(try c.decode(String.self, forKey: .description))
        let steps = (try? c.decode([LearnedWorkflowStep].self, forKey: .steps)) ?? []
        self.steps = Array(steps.prefix(Self.maxSteps))
        self.sources = (try? c.decode([String].self, forKey: .sources)) ?? []
        self.confidence = max(0, min(1, try c.decode(Double.self, forKey: .confidence)))
        self.status = try c.decode(LearnedRuleStatus.self, forKey: .status)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSeenAt = (try? c.decode(Date.self, forKey: .lastSeenAt)) ?? self.createdAt
        self.recurrenceCount = (try? c.decode(Int.self, forKey: .recurrenceCount)) ?? 1
        self.sessionCount = (try? c.decode(Int.self, forKey: .sessionCount)) ?? 0
    }

    public static func sanitizeDescription(_ raw: String) -> String {
        let scanned = SecretDetector.scan(raw).redacted
        if scanned.utf8.count <= maxDescriptionBytes { return scanned }
        var out = scanned
        while out.utf8.count > maxDescriptionBytes { out.removeLast() }
        return out
    }
}
