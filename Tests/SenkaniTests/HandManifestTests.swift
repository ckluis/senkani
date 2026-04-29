import Foundation
import Testing
@testable import Core

@Suite("HandManifest schema v1")
struct HandManifestTests {

    /// Returns a valid baseline manifest used as the happy-path
    /// fixture across the suite. Tests mutate it to introduce
    /// specific violations.
    static func validFixture() -> HandManifest {
        HandManifest(
            schemaVersion: 1,
            name: "code-quality",
            description: "Run the project lint + format pipeline.",
            version: "0.1.0",
            tools: ["search", "exec"],
            settings: ["timeout_seconds": .int(60), "verbose": .bool(false)],
            metrics: ["lint.errors", "lint.warnings"],
            systemPrompt: HandSystemPrompt(phases: [
                HandPromptPhase(
                    name: "preamble",
                    body: "You run lint + format and report failures."),
                HandPromptPhase(
                    name: "rules",
                    body: "Never modify files without confirmation."),
            ]),
            skillMd: "## Usage\n\nRun `senkani skill code-quality` ...",
            guardrails: HandGuardrails(
                requiresConfirm: ["exec"],
                egressAllow: ["api.github.com"],
                secretScope: .session),
            cadence: HandCadence(
                triggers: ["pre_tool", "post_tool"],
                schedule: nil),
            sandbox: .proc,
            capabilities: ["fs.read", "fs.write"])
    }

    @Test("decodes a well-formed manifest from JSON")
    func decodeHappyPath() throws {
        let json = """
        {
          "schema_version": 1,
          "name": "code-quality",
          "description": "Run lint.",
          "version": "0.1.0",
          "tools": ["search"],
          "settings": {"timeout_seconds": 60},
          "metrics": ["lint.errors"],
          "system_prompt": {
            "phases": [
              {"name": "preamble", "body": "do the thing"}
            ]
          },
          "skill_md": "body",
          "guardrails": {
            "requires_confirm": [],
            "egress_allow": [],
            "secret_scope": "none"
          },
          "cadence": {"triggers": ["post_tool"]},
          "sandbox": "none",
          "capabilities": ["fs.read"]
        }
        """
        let data = Data(json.utf8)
        let m = try JSONDecoder().decode(HandManifest.self, from: data)
        #expect(m.name == "code-quality")
        #expect(m.tools == ["search"])
        #expect(m.systemPrompt.phases.first?.name == "preamble")
        #expect(m.guardrails.secretScope == .none)
        #expect(m.sandbox == .none)
    }

    @Test("HandValue decodes string / bool / int")
    func handValueDecode() throws {
        let json = """
        {"a": "s", "b": true, "c": 42}
        """
        let data = Data(json.utf8)
        let m = try JSONDecoder().decode([String: HandValue].self, from: data)
        #expect(m["a"] == .string("s"))
        #expect(m["b"] == .bool(true))
        #expect(m["c"] == .int(42))
    }

    @Test("decode rejects unknown sandbox value")
    func decodeRejectsBadSandbox() {
        let json = """
        {
          "schema_version": 1, "name": "x", "description": "x",
          "version": "0.1.0", "tools": [], "settings": {}, "metrics": [],
          "system_prompt": {"phases": [{"name": "p", "body": "b"}]},
          "skill_md": "", "guardrails": {"requires_confirm": [],
            "egress_allow": [], "secret_scope": "none"},
          "cadence": {"triggers": []},
          "sandbox": "vm",
          "capabilities": []
        }
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(HandManifest.self, from: Data(json.utf8))
        }
    }

    @Test("multi-phase system prompt round-trips")
    func multiPhaseRoundTrip() throws {
        let m = Self.validFixture()
        let data = try JSONEncoder().encode(m)
        let back = try JSONDecoder().decode(HandManifest.self, from: data)
        #expect(back.systemPrompt.phases.count == 2)
        #expect(back.systemPrompt.phases[1].name == "rules")
    }
}

@Suite("HandManifestLinter")
struct HandManifestLinterTests {

    @Test("valid fixture lints clean")
    func validClean() {
        let m = HandManifestTests.validFixture()
        let issues = HandManifestLinter.lint(m)
        #expect(!HandManifestLinter.hasErrors(issues))
    }

    @Test("rejects empty name")
    func rejectsEmptyName() {
        var m = HandManifestTests.validFixture()
        m.name = ""
        let issues = HandManifestLinter.lint(m)
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path == "name" && $0.severity == .error })
    }

    @Test("rejects schema_version != 1")
    func rejectsBadSchemaVersion() {
        var m = HandManifestTests.validFixture()
        m.schemaVersion = 2
        let issues = HandManifestLinter.lint(m)
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path == "schema_version" })
    }

    @Test("requires_confirm must reference a declared tool")
    func requiresConfirmReferencesDeclaredTool() {
        var m = HandManifestTests.validFixture()
        m.guardrails.requiresConfirm = ["bogus_tool"]
        let issues = HandManifestLinter.lint(m)
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path.hasPrefix("guardrails.requires_confirm") })
    }

    @Test("rejects unknown cadence triggers")
    func rejectsUnknownTrigger() {
        var m = HandManifestTests.validFixture()
        m.cadence.triggers = ["on_friday"]
        let issues = HandManifestLinter.lint(m)
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path.hasPrefix("cadence.triggers") })
    }

    @Test("rejects empty system_prompt.phases")
    func rejectsEmptyPhases() {
        var m = HandManifestTests.validFixture()
        m.systemPrompt.phases = []
        let issues = HandManifestLinter.lint(m)
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path == "system_prompt.phases" })
    }

    @Test("warns on non-kebab-case name")
    func warnsOnNonKebab() {
        var m = HandManifestTests.validFixture()
        m.name = "Code Quality"
        let issues = HandManifestLinter.lint(m)
        // Has a warning, but no errors (name is non-empty).
        #expect(!HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path == "name" && $0.severity == .warning })
    }

    @Test("lintJSON surfaces decode failures as errors")
    func lintJSONDecodeFailure() {
        let issues = HandManifestLinter.lintJSON(Data("{not json".utf8))
        #expect(HandManifestLinter.hasErrors(issues))
        #expect(issues.contains { $0.path == "(decode)" })
    }
}

@Suite("HandManifestExporter")
struct HandManifestExporterTests {

    @Test("claude-code export includes frontmatter and phases as sections")
    func exportClaudeCode() {
        let m = HandManifestTests.validFixture()
        let out = HandManifestExporter.exportClaudeCode(m)
        #expect(out.hasPrefix("---\n"))
        #expect(out.contains("name: code-quality"))
        #expect(out.contains("description: Run the project lint + format pipeline."))
        #expect(out.contains("## Preamble"))
        #expect(out.contains("## Rules"))
        #expect(out.contains("Run `senkani skill code-quality`"))
    }

    @Test("senkani export includes tools + sandbox in frontmatter")
    func exportSenkani() {
        let m = HandManifestTests.validFixture()
        let out = HandManifestExporter.exportSenkani(m)
        #expect(out.contains("tools: [search, exec]"))
        #expect(out.contains("sandbox: proc"))
        #expect(out.contains("version: 0.1.0"))
    }

    @Test("cursor export uses .mdc rule frontmatter")
    func exportCursor() {
        let m = HandManifestTests.validFixture()
        let out = HandManifestExporter.exportCursor(m)
        #expect(out.contains("alwaysApply: false"))
        #expect(out.contains("description:"))
        #expect(out.contains("## Preamble"))
    }

    @Test("codex export emits JSON with harness envelope")
    func exportCodex() throws {
        let m = HandManifestTests.validFixture()
        let out = try HandManifestExporter.export(m, target: .codex)
        let data = Data(out.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["harness"] as? String == "codex")
        let manifest = parsed?["manifest"] as? [String: Any]
        #expect(manifest?["name"] as? String == "code-quality")
    }

    @Test("opencode export emits JSON with harness envelope")
    func exportOpencode() throws {
        let m = HandManifestTests.validFixture()
        let out = try HandManifestExporter.export(m, target: .opencode)
        let data = Data(out.utf8)
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed?["harness"] as? String == "opencode")
    }

    @Test("yamlEscape quotes strings with colons")
    func yamlEscapeColons() {
        let s = HandManifestExporter.yamlEscape("hello: world")
        #expect(s == "\"hello: world\"")
    }

    @Test("humanize splits underscores and capitalises")
    func humanize() {
        #expect(HandManifestExporter.humanize("rules") == "Rules")
        #expect(HandManifestExporter.humanize("do_not_run") == "Do Not Run")
        #expect(HandManifestExporter.humanize("post-merge") == "Post Merge")
    }

    @Test("HandHarness parses by name")
    func parseHarness() {
        #expect(HandHarness(name: "claude-code") == .claudeCode)
        #expect(HandHarness(name: "senkani") == .senkani)
        #expect(HandHarness(name: "bogus") == nil)
    }
}
