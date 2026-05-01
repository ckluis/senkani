import Foundation

/// The harnesses we know how to translate a `HandManifest` into.
/// `claudeCode` and `senkani` are first-class round-trips; the other
/// three emit a canonical JSON shape that the target harness's
/// installer can consume — per-target hardening lands in follow-up
/// rounds (V.10 / V.11 SkillPack work).
public enum HandHarness: String, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case cursor
    case codex
    case opencode
    case senkani

    public init?(name: String) {
        guard let v = HandHarness(rawValue: name) else { return nil }
        self = v
    }
}

/// Stateless translator: `HandManifest` → harness-specific bytes.
public enum HandManifestExporter {

    public static func export(
        _ m: HandManifest,
        target: HandHarness
    ) throws -> String {
        switch target {
        case .claudeCode: return exportClaudeCode(m)
        case .senkani:    return exportSenkani(m)
        case .cursor:     return exportCursor(m)
        case .codex:      return try exportJSON(m, harness: "codex")
        case .opencode:   return try exportJSON(m, harness: "opencode")
        }
    }

    // MARK: - Claude Code (SKILL.md)

    /// Emits a Claude Code `SKILL.md` document: YAML frontmatter
    /// (`name`, `description`) followed by the expanded body. The
    /// system prompt phases are appended as `## <Phase>` sections
    /// before the freeform `skill_md` body — Claude reads the whole
    /// file, so sectioning is for the human reading the file later.
    static func exportClaudeCode(_ m: HandManifest) -> String {
        var out = ""
        out += "---\n"
        out += "name: \(yamlEscape(m.name))\n"
        out += "description: \(yamlEscape(m.description))\n"
        out += "---\n\n"
        for phase in m.systemPrompt.phases {
            out += "## \(humanize(phase.name))\n\n"
            out += phase.body.trimmingCharacters(in: .newlines)
            out += "\n\n"
        }
        if !m.skillMd.isEmpty {
            out += m.skillMd.trimmingCharacters(in: .newlines)
            out += "\n"
        }
        return out
    }

    // MARK: - Senkani (WARP.md)

    /// Senkani's WARP.md is structurally identical to Claude's
    /// SKILL.md (frontmatter + body) but adds a `tools:` line in
    /// frontmatter so `SkillScanner` can route the skill to the
    /// right MCP tool subset without parsing the body.
    static func exportSenkani(_ m: HandManifest) -> String {
        var out = ""
        out += "---\n"
        out += "name: \(yamlEscape(m.name))\n"
        out += "description: \(yamlEscape(m.description))\n"
        out += "version: \(yamlEscape(m.version))\n"
        if !m.tools.isEmpty {
            out += "tools: [\(m.tools.map { yamlEscape($0) }.joined(separator: ", "))]\n"
        }
        out += "sandbox: \(m.sandbox.rawValue)\n"
        out += "---\n\n"
        for phase in m.systemPrompt.phases {
            out += "## \(humanize(phase.name))\n\n"
            out += phase.body.trimmingCharacters(in: .newlines)
            out += "\n\n"
        }
        if !m.skillMd.isEmpty {
            out += m.skillMd.trimmingCharacters(in: .newlines)
            out += "\n"
        }
        return out
    }

    // MARK: - Cursor (.mdc rule)

    /// Cursor `.mdc` rule format: frontmatter with `description`,
    /// `globs`, `alwaysApply`, then the body.
    static func exportCursor(_ m: HandManifest) -> String {
        var out = ""
        out += "---\n"
        out += "description: \(yamlEscape(m.description))\n"
        out += "globs: \"\"\n"
        out += "alwaysApply: false\n"
        out += "---\n\n"
        for phase in m.systemPrompt.phases {
            out += "## \(humanize(phase.name))\n\n"
            out += phase.body.trimmingCharacters(in: .newlines)
            out += "\n\n"
        }
        if !m.skillMd.isEmpty {
            out += m.skillMd.trimmingCharacters(in: .newlines)
            out += "\n"
        }
        return out
    }

    // MARK: - Generic JSON (codex / opencode)

    /// Codex + OpenCode both consume JSON skill descriptors — the
    /// per-harness installer takes the canonical fields we hand it
    /// and integrates with whatever local convention each harness
    /// uses for plugins. Hardening (per-harness key renames, custom
    /// path layouts) is deferred to V.11 SkillPack rounds.
    static func exportJSON(_ m: HandManifest, harness: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = JSONEnvelope(harness: harness, manifest: m)
        let data = try encoder.encode(envelope)
        guard let s = String(data: data, encoding: .utf8) else {
            throw NSError(
                domain: "HandManifestExporter", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "non-UTF8 JSON"])
        }
        return s + "\n"
    }

    private struct JSONEnvelope: Encodable {
        var harness: String
        var manifest: HandManifest
    }

    // MARK: - Helpers

    /// Minimal YAML scalar quoting: wraps in double quotes and
    /// escapes embedded `"` / `\`. Sufficient for short identity
    /// fields; phase bodies go in the markdown body, not frontmatter.
    static func yamlEscape(_ s: String) -> String {
        let needsQuote = s.contains(":") || s.contains("#") || s.contains("\"")
            || s.contains("'") || s.contains("\n") || s.hasPrefix(" ")
            || s.hasSuffix(" ") || s.isEmpty
        if !needsQuote { return s }
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    /// "rules" → "Rules", "do_not_run" → "Do Not Run". Used to turn
    /// machine phase names into human-readable section headers.
    static func humanize(_ s: String) -> String {
        s.split(whereSeparator: { $0 == "_" || $0 == "-" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
