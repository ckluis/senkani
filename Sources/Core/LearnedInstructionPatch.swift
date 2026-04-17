import Foundation

// MARK: - LearnedInstructionPatch
//
// Phase H+2c — proposed refinement to an MCP tool's user-facing hint.
// A patch is a short string added to the tool's description when the
// agent negotiates schemas (or surfaced in `senkani learn status` so
// operators can paste it into prompts manually).
//
// Schneier constraint: instruction patches are the highest-risk signal
// type because they mutate what the agent THINKS a tool does. Default
// lifecycle NEVER auto-promotes from `.staged → .applied`. Every apply
// requires an explicit human-reviewed `senkani learn apply <id>`.
// The daily sweep may promote `.recurring → .staged`, but the auto-path
// stops there. The `SENKANI_INSTRUCTION_AUTO_APPLY=on` opt-in bypass
// exists for power users who accept the risk.
//
// Safety invariants (Schneier / Karpathy):
//   - `hint` ≤ 300 chars + SecretDetector scan at every entry point.
//   - `toolName` restricted to [a-z_] + lowercase — matches
//     `ToolRouter.allTools()` naming. Hand-fabricated patches can't
//     target a synthetic tool namespace.

public struct LearnedInstructionPatch: Codable, Sendable, Equatable {
    public let id: String
    /// Target MCP tool name (e.g., "search", "exec"). Sanitized.
    public let toolName: String
    /// One-line hint appended to the tool's description. Sanitized.
    public var hint: String
    public var sources: [String]
    public let confidence: Double
    public var status: LearnedRuleStatus
    public let createdAt: Date
    public var lastSeenAt: Date
    public var recurrenceCount: Int
    public var sessionCount: Int

    public static let maxHintChars: Int = 300
    public static let maxToolNameChars: Int = 32

    public init(
        id: String,
        toolName: String,
        hint: String,
        sources: [String],
        confidence: Double,
        status: LearnedRuleStatus = .recurring,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        recurrenceCount: Int = 1,
        sessionCount: Int = 0
    ) {
        self.id = id
        self.toolName = Self.sanitizeToolName(toolName)
        self.hint = Self.sanitizeHint(hint)
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
        self.toolName = Self.sanitizeToolName(try c.decode(String.self, forKey: .toolName))
        self.hint = Self.sanitizeHint(try c.decode(String.self, forKey: .hint))
        self.sources = (try? c.decode([String].self, forKey: .sources)) ?? []
        self.confidence = max(0, min(1, try c.decode(Double.self, forKey: .confidence)))
        self.status = try c.decode(LearnedRuleStatus.self, forKey: .status)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSeenAt = (try? c.decode(Date.self, forKey: .lastSeenAt)) ?? self.createdAt
        self.recurrenceCount = (try? c.decode(Int.self, forKey: .recurrenceCount)) ?? 1
        self.sessionCount = (try? c.decode(Int.self, forKey: .sessionCount)) ?? 0
    }

    public static func sanitizeToolName(_ raw: String) -> String {
        let lower = raw.lowercased()
        var out = ""
        for scalar in lower.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c == "_" {
                out.append(c)
            }
        }
        if out.isEmpty { out = "unknown" }
        return String(out.prefix(maxToolNameChars))
    }

    public static func sanitizeHint(_ raw: String) -> String {
        let scanned = SecretDetector.scan(raw).redacted
        let collapsed = scanned
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(collapsed.prefix(maxHintChars))
    }
}
