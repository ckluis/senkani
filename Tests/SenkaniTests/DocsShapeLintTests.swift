import Testing
import Foundation
@testable import Core

@Suite("DocsShapeLint — W.6 Diátaxis four-shape gate")
struct DocsShapeLintTests {

    @Test("all four shapes present and non-empty produces no issues")
    func allShapesPresent() {
        let component = ComponentDocs(
            id: "context-saturation-gate",
            paths: [
                .tutorial:    "docs/guides/context-saturation/install.md",
                .howTo:       "docs/guides/context-saturation/configure.md",
                .reference:   "docs/reference/context-saturation.md",
                .explanation: "docs/concepts/context-saturation.md",
            ]
        )
        let fs = FileSystemProbe.inMemory(files: [
            "docs/guides/context-saturation/install.md":   "step 1",
            "docs/guides/context-saturation/configure.md": "recipe 1",
            "docs/reference/context-saturation.md":        "schema",
            "docs/concepts/context-saturation.md":         "why",
        ])
        let issues = DocsShapeLinter.lint(components: [component], fileSystem: fs)
        #expect(issues.isEmpty)
    }

    @Test("missing declaration is flagged with kind .missingDeclaration")
    func missingDeclaration() {
        let component = ComponentDocs(
            id: "amplification-guard",
            paths: [
                // tutorial intentionally omitted
                .howTo:       "docs/guides/amplification/configure.md",
                .reference:   "docs/reference/amplification.md",
                .explanation: "docs/concepts/amplification.md",
            ]
        )
        let fs = FileSystemProbe.inMemory(files: [
            "docs/guides/amplification/configure.md": "recipe",
            "docs/reference/amplification.md":        "schema",
            "docs/concepts/amplification.md":         "why",
        ])
        let issues = DocsShapeLinter.lint(components: [component], fileSystem: fs)
        #expect(issues.count == 1)
        #expect(issues.first?.shape == .tutorial)
        #expect(issues.first?.kind == .missingDeclaration)
        #expect(issues.first?.componentID == "amplification-guard")
    }

    @Test("declared but missing-on-disk file is flagged with kind .fileNotFound")
    func fileNotFound() {
        let component = ComponentDocs(
            id: "chain-verifier",
            paths: [
                .tutorial:    "docs/guides/chain/verify.md",
                .howTo:       "docs/guides/chain/repair.md",
                .reference:   "docs/reference/chain.md",
                .explanation: "docs/concepts/chain.md",
            ]
        )
        // Note: how-to file is *not* on disk.
        let fs = FileSystemProbe.inMemory(files: [
            "docs/guides/chain/verify.md": "step",
            "docs/reference/chain.md":     "schema",
            "docs/concepts/chain.md":      "why",
        ])
        let issues = DocsShapeLinter.lint(components: [component], fileSystem: fs)
        #expect(issues.count == 1)
        #expect(issues.first?.shape == .howTo)
        #expect(issues.first?.kind == .fileNotFound)
        #expect(issues.first?.path == "docs/guides/chain/repair.md")
    }

    @Test("multi-component fixture: missing reference + empty explanation flagged in declared order")
    func multiComponentIssues() {
        let goodComponent = ComponentDocs(
            id: "good",
            paths: [
                .tutorial:    "g/t.md",
                .howTo:       "g/h.md",
                .reference:   "g/r.md",
                .explanation: "g/e.md",
            ]
        )
        let badComponent = ComponentDocs(
            id: "bad",
            paths: [
                .tutorial:    "b/t.md",
                .howTo:       "b/h.md",
                // reference declared but file missing
                .reference:   "b/r.md",
                // explanation declared but file is empty
                .explanation: "b/e.md",
            ]
        )
        let fs = FileSystemProbe.inMemory(files: [
            "g/t.md": "x", "g/h.md": "x", "g/r.md": "x", "g/e.md": "x",
            "b/t.md": "x", "b/h.md": "x",
            // "b/r.md" omitted entirely
            "b/e.md": "",     // declared, exists, empty
        ])
        let issues = DocsShapeLinter.lint(
            components: [goodComponent, badComponent],
            fileSystem: fs
        )
        #expect(issues.count == 2)
        #expect(issues[0].componentID == "bad")
        #expect(issues[0].shape == .reference)
        #expect(issues[0].kind == .fileNotFound)
        #expect(issues[1].componentID == "bad")
        #expect(issues[1].shape == .explanation)
        #expect(issues[1].kind == .fileEmpty)
    }
}
