import Foundation

// MARK: - LearnedContextDoc
//
// Phase H+2b — priming document artifact emitted by
// `ContextSignalGenerator`. A context doc is a short markdown snippet
// that gets injected into future session briefs so the agent doesn't
// re-learn a fact the system has already observed (e.g., "this project
// uses Swift 6 strict concurrency," "tests live under Tests/",
// "Package.swift is the source of truth").
//
// Separate artifact type — deliberately NOT a subclass/variant of
// `LearnedFilterRule`. Filter rules mutate tool OUTPUT; context docs
// mutate session INPUT. Different axis, different safety story.
//
// Safety invariants (Schneier / Karpathy):
//   - `body` is always ≤ `maxBodyBytes` (2 KB).
//   - `body` is always `SecretDetector.scan`-ed at construction AND
//     at every write to disk. Belt + suspenders: a malformed
//     constructor caller can't smuggle a secret past the on-disk
//     scan even if they fabricate a `LearnedContextDoc` by hand.
//   - `title` is a filesystem-safe slug — lowercase, [a-z0-9-] only,
//     so `.senkani/context/<title>.md` can never contain `..` or `/`.

public struct LearnedContextDoc: Codable, Sendable, Equatable {
    /// Stable UUID.
    public let id: String
    /// Filesystem-safe slug used for `.senkani/context/<title>.md`.
    public let title: String
    /// Markdown body. Capped at `maxBodyBytes` and secret-scanned.
    public var body: String
    /// Session ids that contributed to the observation.
    public var sources: [String]
    /// Laplace-smoothed posterior confidence (reuse Phase K estimator).
    public let confidence: Double
    /// Lifecycle state — reuses `LearnedRuleStatus` vocabulary
    /// (recurring → staged → applied | rejected). Applied context docs
    /// are the ones that appear in future session briefs.
    public var status: LearnedRuleStatus
    /// When this was first proposed.
    public let createdAt: Date
    /// Most recent re-observation.
    public var lastSeenAt: Date
    /// How many post-session runs have re-proposed this pattern.
    public var recurrenceCount: Int
    /// Distinct sessions observed.
    public var sessionCount: Int

    /// Body size cap (bytes). 2 KB matches the instruction-payload
    /// budget default — a single context doc must never dominate the
    /// session brief.
    public static let maxBodyBytes: Int = 2048

    /// Title length cap (chars). Keeps `.senkani/context/<title>.md`
    /// well under filesystem PATH_MAX even on pathological setups.
    public static let maxTitleChars: Int = 64

    public init(
        id: String,
        title: String,
        body: String,
        sources: [String],
        confidence: Double,
        status: LearnedRuleStatus = .recurring,
        createdAt: Date = Date(),
        lastSeenAt: Date? = nil,
        recurrenceCount: Int = 1,
        sessionCount: Int = 0
    ) {
        self.id = id
        self.title = Self.sanitizeTitle(title)
        self.body = Self.sanitizeBody(body)
        self.sources = sources
        self.confidence = max(0, min(1, confidence))
        self.status = status
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt ?? createdAt
        self.recurrenceCount = max(1, recurrenceCount)
        self.sessionCount = max(0, sessionCount)
    }

    /// Decoder re-runs the sanitizers so a hand-edited JSON file
    /// (pathological content pushed in by a prompt-injected subagent)
    /// can't smuggle an over-budget body or a path-unsafe title.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.title = Self.sanitizeTitle(try c.decode(String.self, forKey: .title))
        self.body = Self.sanitizeBody(try c.decode(String.self, forKey: .body))
        self.sources = (try? c.decode([String].self, forKey: .sources)) ?? []
        self.confidence = max(0, min(1, try c.decode(Double.self, forKey: .confidence)))
        self.status = try c.decode(LearnedRuleStatus.self, forKey: .status)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.lastSeenAt = (try? c.decode(Date.self, forKey: .lastSeenAt)) ?? self.createdAt
        self.recurrenceCount = (try? c.decode(Int.self, forKey: .recurrenceCount)) ?? 1
        self.sessionCount = (try? c.decode(Int.self, forKey: .sessionCount)) ?? 0
    }

    // MARK: - Sanitizers

    /// Lowercase, hyphenate non-alphanumerics, collapse runs, cap length.
    /// Guarantees the result is safe for `.senkani/context/<title>.md`.
    public static func sanitizeTitle(_ raw: String) -> String {
        let lower = raw.lowercased()
        var out = ""
        var lastWasDash = false
        for scalar in lower.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        // Trim leading / trailing dashes.
        while out.first == "-" { out.removeFirst() }
        while out.last == "-" { out.removeLast() }
        // Fallback slug so we never produce an empty title.
        if out.isEmpty { out = "context" }
        return String(out.prefix(maxTitleChars))
    }

    /// Run `SecretDetector.scan`, cap at `maxBodyBytes`. Called at
    /// init, at decode, and at every on-disk write — defense in depth.
    public static func sanitizeBody(_ raw: String) -> String {
        let scanned = SecretDetector.scan(raw).redacted
        if scanned.utf8.count <= maxBodyBytes { return scanned }
        // UTF-8 safe truncation — drop from the end until under budget.
        var out = scanned
        while out.utf8.count > maxBodyBytes {
            out.removeLast()
        }
        return out
    }
}
