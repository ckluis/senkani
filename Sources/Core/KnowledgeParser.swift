import Foundation
import CryptoKit

// MARK: - Public Types

public struct KBFrontmatter: Sendable, Equatable {
    public let entityType: String    // class|struct|func|file|concept
    public let sourcePath: String?
    public let lastEnriched: Date?
    public let mentionCount: Int

    public init(entityType: String = "concept", sourcePath: String? = nil,
                lastEnriched: Date? = nil, mentionCount: Int = 0) {
        self.entityType = entityType; self.sourcePath = sourcePath
        self.lastEnriched = lastEnriched; self.mentionCount = mentionCount
    }
}

public struct ParsedRelation: Sendable, Equatable {
    public let targetName: String
    public let relationType: String?
    public let lineNumber: Int

    public init(targetName: String, relationType: String? = nil, lineNumber: Int = 0) {
        self.targetName = targetName; self.relationType = relationType; self.lineNumber = lineNumber
    }
}

public struct ParsedEvidence: Sendable, Equatable {
    public let date: Date
    public let sessionId: String
    public let whatWasLearned: String

    public init(date: Date, sessionId: String, whatWasLearned: String) {
        self.date = date; self.sessionId = sessionId; self.whatWasLearned = whatWasLearned
    }
}

public struct ParsedDecision: Sendable, Equatable {
    public let date: Date
    public let decision: String
    public let rationale: String?

    public init(date: Date, decision: String, rationale: String? = nil) {
        self.date = date; self.decision = decision; self.rationale = rationale
    }
}

public struct KBContent: Sendable, Equatable {
    public let frontmatter: KBFrontmatter
    public let entityName: String
    public let compiledUnderstanding: String
    public let relations: [ParsedRelation]
    public let evidence: [ParsedEvidence]
    public let decisions: [ParsedDecision]

    public init(frontmatter: KBFrontmatter, entityName: String,
                compiledUnderstanding: String = "",
                relations: [ParsedRelation] = [],
                evidence: [ParsedEvidence] = [],
                decisions: [ParsedDecision] = []) {
        self.frontmatter = frontmatter; self.entityName = entityName
        self.compiledUnderstanding = compiledUnderstanding
        self.relations = relations; self.evidence = evidence; self.decisions = decisions
    }
}

// MARK: - KnowledgeParser

/// Pure, stateless markdown parser/serializer for .senkani/knowledge/*.md files.
/// No file I/O — takes and returns strings only.
/// SECURITY: Calls SecretDetector.scan() before any field extraction.
public enum KnowledgeParser {

    // MARK: Date Formatters (compiled once, thread-safe)

    // ISO8601 with time component — for last_enriched in frontmatter
    nonisolated(unsafe) static let isoFull: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // Date-only — for evidence table rows and decision records
    nonisolated(unsafe) static let isoDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    // MARK: Compiled Regexes (compiled once, thread-safe)

    // Frontmatter block: ---\n...\n---
    nonisolated(unsafe) static let frontmatterRE: NSRegularExpression =
        try! NSRegularExpression(pattern: "\\A---[ \\t]*\\n([\\s\\S]*?)\\n---", options: [])

    // H1 heading: # EntityName
    nonisolated(unsafe) static let h1RE: NSRegularExpression =
        try! NSRegularExpression(pattern: "^# (.+)$", options: .anchorsMatchLines)

    // Wiki-link relation: [[TargetName]] relation_type
    nonisolated(unsafe) static let wikiLinkRE: NSRegularExpression =
        try! NSRegularExpression(pattern: "\\[\\[([^\\]]+)\\]\\](?:\\s+([\\w_]+))?", options: [])

    // Decision record: - [YYYY-MM-DD] text  or  - [YYYY-MM-DD] text because rationale
    nonisolated(unsafe) static let decisionRE: NSRegularExpression =
        try! NSRegularExpression(
            pattern: "^- \\[(\\d{4}-\\d{2}-\\d{2})\\] (.+?)(?:\\s+because\\s+(.+))?$",
            options: .anchorsMatchLines)

    // MARK: Parse

    /// Parse a markdown string into KBContent.
    /// Returns nil if frontmatter block or H1 entity name is missing.
    /// SECURITY: runs SecretDetector.scan() on raw input before extracting any field.
    public static func parse(_ markdown: String) -> KBContent? {
        guard markdown.count <= 1_048_576 else {
            fputs("[KnowledgeParser] File too large (>1MB), refusing to parse\n", stderr)
            return nil
        }

        // Always parse from the secret-scrubbed version
        let safe = SecretDetector.scan(markdown).redacted
        let ns = safe as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1. Extract frontmatter
        guard let fmMatch = frontmatterRE.firstMatch(in: safe, range: fullRange) else { return nil }
        let fmBody = ns.substring(with: fmMatch.range(at: 1))
        let frontmatter = parseFrontmatter(fmBody)

        // Content after the closing ---
        let afterFM = String(safe.dropFirst(fmMatch.range.length)).trimmingCharacters(in: .newlines)
        let afterNS = afterFM as NSString
        let afterRange = NSRange(location: 0, length: afterNS.length)

        // 2. Extract H1 entity name
        guard let h1Match = h1RE.firstMatch(in: afterFM, range: afterRange) else { return nil }
        let entityName = afterNS.substring(with: h1Match.range(at: 1))
            .trimmingCharacters(in: .whitespaces)

        // 3. Split into named sections (split on \n## )
        let sections = splitSections(afterFM)

        // 4. Parse each section
        let understanding = sections["Compiled Understanding"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let relations = parseRelations(sections["Relations"] ?? "")
        let evidence  = parseEvidence(sections["Evidence Timeline"] ?? "")
        let decisions = parseDecisions(sections["Decision Records"] ?? "")

        return KBContent(
            frontmatter: frontmatter,
            entityName: entityName,
            compiledUnderstanding: understanding,
            relations: relations,
            evidence: evidence,
            decisions: decisions
        )
    }

    // MARK: Serialize

    /// Produce canonical markdown from KBContent.
    /// Invariant: parse(serialize(content, name)) == content (when content was itself parsed from
    /// canonical format, or constructed with the same field invariants).
    public static func serialize(_ content: KBContent, entityName: String) -> String {
        var out = ""

        // Frontmatter
        out += "---\n"
        out += "type: \(content.frontmatter.entityType)\n"
        if let sp = content.frontmatter.sourcePath { out += "source_path: \(sp)\n" }
        if let le = content.frontmatter.lastEnriched { out += "last_enriched: \(isoFull.string(from: le))\n" }
        out += "mention_count: \(content.frontmatter.mentionCount)\n"
        out += "---\n\n"

        // H1
        out += "# \(entityName)\n\n"

        // Compiled Understanding
        out += "## Compiled Understanding\n"
        if !content.compiledUnderstanding.isEmpty { out += content.compiledUnderstanding + "\n" }
        out += "\n"

        // Relations
        out += "## Relations\n"
        for rel in content.relations {
            if let rt = rel.relationType {
                out += "- [[\(rel.targetName)]] \(rt)\n"
            } else {
                out += "- [[\(rel.targetName)]]\n"
            }
        }
        out += "\n"

        // Evidence Timeline
        out += "## Evidence Timeline\n"
        out += "| Date | Session | What was learned |\n"
        out += "| --- | --- | --- |\n"
        for ev in content.evidence {
            let d = isoDate.string(from: ev.date)
            // Escape pipes in cell content to avoid breaking table structure
            let learned = ev.whatWasLearned.replacingOccurrences(of: "|", with: "\\|")
            out += "| \(d) | \(ev.sessionId) | \(learned) |\n"
        }
        out += "\n"

        // Decision Records
        out += "## Decision Records\n"
        for dec in content.decisions {
            let d = isoDate.string(from: dec.date)
            if let r = dec.rationale {
                out += "- [\(d)] \(dec.decision) because \(r)\n"
            } else {
                out += "- [\(d)] \(dec.decision)\n"
            }
        }
        out += "\n"

        return out
    }

    // MARK: SHA-256

    /// SHA-256 hex string of data. Uses CryptoKit (hardware-accelerated on Apple Silicon).
    internal static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: Private Helpers

    private static func parseFrontmatter(_ body: String) -> KBFrontmatter {
        var entityType = "concept"
        var sourcePath: String? = nil
        var lastEnriched: Date? = nil
        var mentionCount = 0

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2 else { continue }
            let key = parts[0]; let value = parts[1]
            switch key {
            case "type":          entityType = value
            case "source_path":   sourcePath = value.isEmpty ? nil : value
            case "last_enriched": lastEnriched = isoFull.date(from: value)
            case "mention_count": mentionCount = Int(value) ?? 0
            default: break
            }
        }
        return KBFrontmatter(entityType: entityType, sourcePath: sourcePath,
                             lastEnriched: lastEnriched, mentionCount: mentionCount)
    }

    /// Split the post-frontmatter body into a dict of section name → section body.
    /// Each section starts with `## `. The H1 line is ignored (not added to any section).
    private static func splitSections(_ body: String) -> [String: String] {
        var sections: [String: String] = [:]
        var currentName: String? = nil
        var currentLines: [String] = []

        func flush() {
            if let name = currentName {
                sections[name] = currentLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        for line in body.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                currentName = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                currentLines = []
            } else {
                // Skip the H1 line (it starts with "# " but not "## ")
                if line.hasPrefix("# ") && currentName == nil { continue }
                currentLines.append(line)
            }
        }
        flush()
        return sections
    }

    private static func parseRelations(_ body: String) -> [ParsedRelation] {
        var out: [ParsedRelation] = []
        let lines = body.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            guard let m = wikiLinkRE.firstMatch(in: trimmed, range: range) else { continue }
            let targetName = ns.substring(with: m.range(at: 1))
                .trimmingCharacters(in: .whitespaces)
            let relationType: String?
            if m.range(at: 2).location != NSNotFound {
                let rt = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                relationType = rt.isEmpty ? nil : rt
            } else {
                relationType = nil
            }
            out.append(ParsedRelation(targetName: targetName, relationType: relationType, lineNumber: i + 1))
        }
        return out
    }

    private static func parseEvidence(_ body: String) -> [ParsedEvidence] {
        var out: [ParsedEvidence] = []
        var headerSkipped = false
        var separatorSkipped = false

        for line in body.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("|") else { continue }

            // Skip header row (contains "Date")
            if !headerSkipped {
                headerSkipped = true
                continue
            }
            // Skip separator row (contains ---)
            if !separatorSkipped {
                separatorSkipped = true
                continue
            }

            // Data row: | date | session | what was learned |
            let cells = trimmed
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard cells.count >= 3 else { continue }
            guard let date = isoDate.date(from: cells[0]) else { continue }
            let sessionId = cells[1]
            let learned = cells[2].replacingOccurrences(of: "\\|", with: "|") // unescape
            out.append(ParsedEvidence(date: date, sessionId: sessionId, whatWasLearned: learned))
        }
        return out
    }

    private static func parseDecisions(_ body: String) -> [ParsedDecision] {
        var out: [ParsedDecision] = []
        let ns = body as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = decisionRE.matches(in: body, range: fullRange)
        for m in matches {
            let dateStr  = ns.substring(with: m.range(at: 1))
            let decision = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
            guard let date = isoDate.date(from: dateStr) else { continue }
            let rationale: String?
            if m.range(at: 3).location != NSNotFound {
                let r = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
                rationale = r.isEmpty ? nil : r
            } else {
                rationale = nil
            }
            out.append(ParsedDecision(date: date, decision: decision, rationale: rationale))
        }
        return out
    }
}
