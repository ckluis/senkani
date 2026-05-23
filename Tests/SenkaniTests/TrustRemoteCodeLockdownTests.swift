import Testing
import Foundation
@testable import Core

/// V.19a-5 — `trust_remote_code` lockdown regression.
///
/// `tests_target: 1` — a single regression test that covers all four
/// acceptance bullets in one file (acceptance bullet 3 explicitly
/// requires the template-source and import-source flip attempts in
/// "a single test file"):
///
///   1. `HandManifestLinter` flags a template manifest whose
///      `settings["trust_remote_code"]` is `.bool(true)` and refuses
///      to lint-pass it (covers acceptance bullets 1 + 3 — template
///      source).
///   2. The same flag is flagged when introduced via the JSON
///      `lintJSON` import path (covers acceptance bullets 2 + 3 —
///      import source). Three canonical spellings are exercised:
///      `trust_remote_code` (snake), `trustRemoteCode` (camel),
///      `TRUST_REMOTE_CODE` (screaming snake).
///   3. The default-off case passes lint clean — a manifest without
///      the key, or with the key set to `false`, MUST NOT trip the
///      gate (covers acceptance bullet 4 — regression preserves
///      default-off behavior).
///   4. `ModelPreset` is a closed `String` enum with no
///      associated-value cases — by construction it cannot carry a
///      `trust_remote_code` flag through any "import path." This
///      assertion uses `Mirror` over every case to catch a future
///      refactor that adds an associated value (covers acceptance
///      bullet 2 — ModelPreset import path rejection by API shape).
@Suite("V.19a-5 — trust_remote_code lockdown regression")
struct TrustRemoteCodeLockdownTests {

    private static func makeBaseManifest(
        settings: [String: HandValue] = [:]
    ) -> HandManifest {
        return HandManifest(
            schemaVersion: 1,
            name: "regression-fixture",
            description: "fixture for v19a-5 lockdown regression",
            version: "0.1.0",
            tools: ["senkani_read"],
            settings: settings,
            metrics: [],
            systemPrompt: HandSystemPrompt(phases: [
                HandPromptPhase(name: "scaffold", body: "ship code + tests"),
            ]),
            skillMd: "",
            guardrails: .empty,
            cadence: .empty,
            sandbox: .none,
            capabilities: []
        )
    }

    @Test("trust_remote_code lockdown: template + import flip attempts blocked; default-off passes; ModelPreset closed by construction")
    func trustRemoteCodeLockdown() throws {
        // -- Bullet 1: template-source flip attempts (every spelling). --

        let canonicalKeys = ["trust_remote_code", "trustRemoteCode", "TRUST_REMOTE_CODE"]
        for key in canonicalKeys {
            let m = Self.makeBaseManifest(settings: [key: .bool(true)])
            let issues = HandManifestLinter.lint(m)
            #expect(HandManifestLinter.hasErrors(issues),
                    "lint MUST flag settings.\(key) = true")
            let matched = issues.contains { issue in
                issue.severity == .error
                    && issue.path == "settings.\(key)"
                    && issue.message.contains("MUST NOT be true")
            }
            #expect(matched,
                    "lint output MUST include the canonical 'MUST NOT be true' error for settings.\(key); got: \(issues.map { "\($0.severity) \($0.path): \($0.message)" })")
        }

        // -- Bullet 2: import-source flip attempts (JSON decode + lint). --

        let importJSON = """
        {
          "schema_version": 1,
          "name": "imported-fixture",
          "description": "fixture for v19a-5 import path",
          "version": "0.1.0",
          "tools": ["senkani_read"],
          "settings": { "trust_remote_code": true },
          "metrics": [],
          "system_prompt": { "phases": [ { "name": "scaffold", "body": "ship" } ] },
          "skill_md": "",
          "guardrails": { "egress_allow": [], "requires_confirm": [], "secret_scope": "none" },
          "cadence": { "triggers": [] },
          "sandbox": "none",
          "capabilities": []
        }
        """.data(using: .utf8)!
        let importIssues = HandManifestLinter.lintJSON(importJSON)
        #expect(HandManifestLinter.hasErrors(importIssues),
                "lintJSON MUST flag settings.trust_remote_code = true on the import path")
        let importMatched = importIssues.contains { issue in
            issue.severity == .error
                && issue.path == "settings.trust_remote_code"
                && issue.message.contains("MUST NOT be true")
        }
        #expect(importMatched,
                "lintJSON import-path output MUST include the canonical error; got: \(importIssues.map { "\($0.severity) \($0.path): \($0.message)" })")

        // -- Bullet 4: default-off case passes (key absent OR explicitly false). --

        let absent = Self.makeBaseManifest(settings: [:])
        let absentIssues = HandManifestLinter.lint(absent)
        let absentErrors = absentIssues.filter { $0.path.hasPrefix("settings.trust") }
        #expect(absentErrors.isEmpty,
                "lint MUST NOT emit a trust_remote_code error when the key is absent; got: \(absentErrors.map { "\($0.severity) \($0.path): \($0.message)" })")

        for key in canonicalKeys {
            let explicitFalse = Self.makeBaseManifest(settings: [key: .bool(false)])
            let issues = HandManifestLinter.lint(explicitFalse)
            let trustErrors = issues.filter { $0.path == "settings.\(key)" }
            #expect(trustErrors.isEmpty,
                    "lint MUST NOT flag settings.\(key) = false (the default-off case); got: \(trustErrors.map { "\($0.severity) \($0.path): \($0.message)" })")
        }

        // -- Bullet 2 (continued): ModelPreset is closed by construction.   --
        // -- ModelPreset is a raw-value String enum with no associated      --
        // -- values; a `Mirror` over each case has zero children. A future  --
        // -- refactor that introduces an associated value (the only way to  --
        // -- attach a flag like `trust_remote_code` to a case payload)      --
        // -- breaks this assertion.                                          --

        for preset in ModelPreset.allCases {
            let mirror = Mirror(reflecting: preset)
            #expect(mirror.children.isEmpty,
                    "ModelPreset case \(preset) MUST have no associated values — closed-by-construction is the V.19a-5 lockdown guarantee that no 'import path' can attach a trust_remote_code flag")
            // Raw-value sanity check: every case maps to a non-empty
            // String — preserves the "no schema-shape carrier" property.
            #expect(!preset.rawValue.isEmpty)
        }
    }
}
