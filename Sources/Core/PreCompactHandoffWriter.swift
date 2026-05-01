import Foundation

/// W.4 — PreCompactHandoffWriter.
///
/// Structured handoff card written before context compaction so the
/// next session can resume cleanly. Cards are JSON-serialised and
/// landed atomically (write-temp + rename) under a per-user directory
/// so a crash mid-write never leaves a half-written file readable.
///
/// Schema fields are pinned by the W.4 acceptance row:
///   * `openFiles`         — what the agent was looking at.
///   * `currentIntent`     — one-sentence "what I'm trying to do".
///   * `lastValidation`    — most-recent validation outcome (if any),
///                            so the next session knows where the
///                            previous one stopped.
///   * `nextActionHint`    — single concrete next step.
///
/// Every other field (sessionId, savedAt, contextPercent,
/// recentTraceKeys) is bookkeeping that lets the loader place the
/// card into the right pane / model context.
///
/// Reference:
/// `spec/inspirations/skills-ecosystem/continuous-claude-v4-7.md`.
public struct HandoffCard: Codable, Equatable, Sendable {

    /// Bumped whenever a non-additive schema change ships. The loader
    /// returns nil on unknown schema versions rather than guessing.
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let sessionId: String
    public let savedAt: Date
    public let contextPercent: Double?
    public let openFiles: [String]
    public let currentIntent: String
    public let lastValidation: ValidationSummary?
    public let nextActionHint: String?
    public let recentTraceKeys: [String]

    public struct ValidationSummary: Codable, Equatable, Sendable {
        public let outcome: String
        public let filePath: String
        public let advisory: String
        public init(outcome: String, filePath: String, advisory: String) {
            self.outcome = outcome
            self.filePath = filePath
            self.advisory = advisory
        }
    }

    public init(
        schemaVersion: Int = HandoffCard.currentSchemaVersion,
        sessionId: String,
        savedAt: Date,
        contextPercent: Double? = nil,
        openFiles: [String] = [],
        currentIntent: String,
        lastValidation: ValidationSummary? = nil,
        nextActionHint: String? = nil,
        recentTraceKeys: [String] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionId = sessionId
        self.savedAt = savedAt
        self.contextPercent = contextPercent
        self.openFiles = openFiles
        self.currentIntent = currentIntent
        self.lastValidation = lastValidation
        self.nextActionHint = nextActionHint
        self.recentTraceKeys = recentTraceKeys
    }
}

public enum PreCompactHandoffWriter {

    /// Default root dir for handoff cards: `~/.senkani/handoffs/`.
    /// Tests inject an alternative root so they don't pollute home.
    public static func defaultRootDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".senkani", isDirectory: true)
            .appendingPathComponent("handoffs", isDirectory: true)
    }

    /// Filename for a card: `<sessionId>.json`. Session ids are
    /// fingerprints (no path separators) by construction; we
    /// percent-encode any odd character to keep the path safe.
    public static func cardURL(sessionId: String, rootDir: URL? = nil) -> URL {
        let dir = rootDir ?? defaultRootDir()
        let safe = safeFilename(sessionId)
        return dir.appendingPathComponent("\(safe).json", isDirectory: false)
    }

    /// Write `card` to disk. Atomic: serialise to a temp file in the
    /// same directory, fsync, rename into place. Returns the destination
    /// URL on success.
    @discardableResult
    public static func write(_ card: HandoffCard, rootDir: URL? = nil) throws -> URL {
        let dest = cardURL(sessionId: card.sessionId, rootDir: rootDir)
        let dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(card)

        let tmp = dir.appendingPathComponent(".\(dest.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp, options: .atomic)
        // `Data.write(.atomic)` already does temp+rename, but we want the
        // rename to land under the canonical name. The two-step lets us
        // verify the bytes hit disk before exposing the destination
        // filename to readers.
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Compose a card from `SessionDatabase` facts plus caller-provided
    /// intent/openFiles/nextAction. The DB-derived bits are
    /// `recentTraceKeys` (last 10 trace ids in the pane) and
    /// `lastValidation` (most-recent advisory row for the session).
    /// `now` is injectable for deterministic tests.
    public static func compose(
        database: SessionDatabase,
        sessionId: String,
        currentIntent: String,
        openFiles: [String] = [],
        nextActionHint: String? = nil,
        contextPercent: Double? = nil,
        pane: String? = nil,
        project: String? = nil,
        now: Date = Date()
    ) -> HandoffCard {
        let recent = database.agentTraceRecentKeys(pane: pane, project: project, limit: 10)
        let validations = database.validationResults(sessionId: sessionId)
        let last = validations.first.map {
            HandoffCard.ValidationSummary(
                outcome: $0.outcome,
                filePath: $0.filePath,
                advisory: $0.advisory
            )
        }
        return HandoffCard(
            sessionId: sessionId,
            savedAt: now,
            contextPercent: contextPercent,
            openFiles: openFiles,
            currentIntent: currentIntent,
            lastValidation: last,
            nextActionHint: nextActionHint,
            recentTraceKeys: recent
        )
    }

    private static func safeFilename(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        return String(s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
    }
}

/// Loader companion to `PreCompactHandoffWriter`. The next session
/// reads the card on start to seed its context.
public enum PreCompactHandoffLoader {

    /// Load the card for `sessionId`. Returns nil when the file is
    /// missing, unreadable, malformed, or written under a schema
    /// version this build doesn't understand. The "no fallback" policy
    /// is intentional — Norman: a card the next session can't trust
    /// is worse than no card.
    public static func load(sessionId: String, rootDir: URL? = nil) -> HandoffCard? {
        let url = PreCompactHandoffWriter.cardURL(sessionId: sessionId, rootDir: rootDir)
        return loadAt(url)
    }

    /// Load the most-recently-saved card under `rootDir`. Convenience
    /// for callers that don't know the session id (e.g. cold-start
    /// loaders that resume the last session).
    public static func loadLatest(rootDir: URL? = nil) -> HandoffCard? {
        let dir = rootDir ?? PreCompactHandoffWriter.defaultRootDir()
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let cards = entries.filter { $0.pathExtension == "json" }
        guard let latest = cards.max(by: { lhs, rhs in
            let lm = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rm = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lm < rm
        }) else { return nil }

        return loadAt(latest)
    }

    private static func loadAt(_ url: URL) -> HandoffCard? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let card = try? decoder.decode(HandoffCard.self, from: data) else { return nil }
        guard card.schemaVersion == HandoffCard.currentSchemaVersion else { return nil }
        return card
    }
}
