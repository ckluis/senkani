import Testing
import Foundation
@testable import Core

// Coverage for `onboarding-p1-first-value-layout`.
//
// `FirstValueLayout` is a pure decider: given a `TaskStarter.Kind` and
// the workspace's existing pane type IDs, it returns the spec list the
// launcher should add. These tests pin down the contract:
//
//   - First-run Claude/Shell launches add a primary terminal AND an
//     Agent Timeline insight pane so optimization events surface
//     immediately, without the user opening a third pane manually.
//   - First-run Ollama and Inspect launches add only the primary pane
//     (their UI already carries the proof/status surface).
//   - Subsequent launches in a non-empty workspace add ONLY the
//     primary pane — clicking the same starter twice never stacks
//     extra timelines next to extra terminals.
//   - The insight pane's typeID matches `PaneGalleryEntry.id` so it
//     resolves to a real `PaneType` at the launch site.
//   - Each starter kind's primary spec maps to a `PaneType` raw value
//     the SwiftUI layer can resolve.
//
// Plus a source-level guard that the SwiftUI assembler in ContentView
// actually goes through `FirstValueLayout` (so behavioral tests in
// SenkaniApp aren't needed to catch regression of the wiring).

private let repoRoot: String = {
    var url = URL(fileURLWithPath: #filePath)
    while url.pathComponents.count > 1 {
        url.deleteLastPathComponent()
        let pkg = url.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: pkg.path) {
            return url.path
        }
    }
    return FileManager.default.currentDirectoryPath
}()

private func read(_ rel: String) -> String {
    let path = (repoRoot as NSString).appendingPathComponent(rel)
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
}

@Suite("Onboarding P1 — first-value layout assembler")
struct FirstValueLayoutTests {

    @Test("First-run Claude launch adds terminal + Agent Timeline")
    func firstRunClaudeAddsInsightPane() {
        let specs = FirstValueLayout.assemble(
            for: .claude, existingPaneTypeIDs: []
        )
        #expect(specs.count == 2,
                "First-run Claude must add primary + insight (got \(specs.count)).")
        #expect(specs.first?.typeID == "terminal",
                "Primary pane must be a terminal.")
        #expect(specs.first?.role == .primary,
                "First spec must be marked role: .primary.")
        #expect(specs.first?.title == "Claude Code",
                "Primary terminal must default to the 'Claude Code' title.")
        #expect(specs.last?.typeID == "agentTimeline",
                "Insight pane must be the agentTimeline so events surface immediately.")
        #expect(specs.last?.role == .insight,
                "Insight spec must be marked role: .insight.")
    }

    @Test("First-run tracked-shell launch adds terminal + Agent Timeline")
    func firstRunShellAddsInsightPane() {
        let specs = FirstValueLayout.assemble(
            for: .trackedShell, existingPaneTypeIDs: []
        )
        #expect(specs.map(\.typeID) == ["terminal", "agentTimeline"],
                "Tracked shell must witness with the same insight pane Claude does.")
        #expect(specs.first?.title == "Terminal",
                "Tracked-shell primary pane must use the 'Terminal' default title.")
    }

    @Test("First-run Ollama adds only the launcher (no extra insight)")
    func firstRunOllamaIsOnlyLauncher() {
        let specs = FirstValueLayout.assemble(
            for: .ollama, existingPaneTypeIDs: []
        )
        #expect(specs.count == 1,
                "Ollama's launcher header is its own proof/status surface — no extra pane.")
        #expect(specs.first?.typeID == "ollamaLauncher",
                "Primary must be the ollamaLauncher pane.")
    }

    @Test("First-run Inspect adds only the code editor (no extra insight)")
    func firstRunInspectIsOnlyCodeEditor() {
        let specs = FirstValueLayout.assemble(
            for: .inspectProject, existingPaneTypeIDs: []
        )
        #expect(specs.count == 1,
                "Inspect is the no-agent path; no Agent Timeline next to it.")
        #expect(specs.first?.typeID == "codeEditor",
                "Primary must be the codeEditor pane.")
    }

    @Test("Subsequent Claude launch does not duplicate the insight pane")
    func subsequentClaudeLaunchDoesNotStackInsight() {
        let existing = ["terminal", "agentTimeline"]
        let specs = FirstValueLayout.assemble(
            for: .claude, existingPaneTypeIDs: existing
        )
        #expect(specs.count == 1,
                "Re-clicking 'Ask Claude' must add ONLY the primary terminal, not another timeline.")
        #expect(specs.first?.role == .primary,
                "The single returned spec must be the primary pane.")
        #expect(specs.first?.typeID == "terminal",
                "Subsequent Claude launch primary must remain a terminal.")
    }

    @Test("Subsequent shell launch does not duplicate the insight pane")
    func subsequentShellLaunchDoesNotStackInsight() {
        let existing = ["codeEditor"]
        let specs = FirstValueLayout.assemble(
            for: .trackedShell, existingPaneTypeIDs: existing
        )
        #expect(specs.count == 1,
                "Workspace already has a pane — only the primary terminal joins it.")
        #expect(specs.first?.typeID == "terminal")
        #expect(specs.first?.role == .primary)
    }

    @Test("Every starter kind maps to a real PaneType raw value")
    func everyStarterPrimaryResolvesToPaneType() {
        // Sanity: SwiftUI's launch site does
        // `PaneType(rawValue: spec.typeID) ?? .terminal`. To make sure
        // no kind silently falls back to terminal, check each primary
        // typeID against the known set of pane raw values used in the
        // app today (mirroring `PaneType` enum).
        let knownPaneTypes: Set<String> = [
            "terminal", "ollamaLauncher", "codeEditor", "agentTimeline",
        ]
        for kind: TaskStarter.Kind in [.claude, .ollama, .trackedShell, .inspectProject] {
            let specs = FirstValueLayout.assemble(
                for: kind, existingPaneTypeIDs: []
            )
            for spec in specs {
                #expect(knownPaneTypes.contains(spec.typeID),
                        "Spec typeID '\(spec.typeID)' for kind \(kind) must match a real PaneType raw value.")
            }
        }
    }

    @Test("ContentView wires its starter routing through FirstValueLayout")
    func contentViewWiresAssembler() {
        // Source-level guard. SenkaniTests can't link the SwiftUI
        // target, so we scan the ContentView source to assert the
        // starter routing actually goes through `FirstValueLayout`
        // instead of the previous one-pane `addPane(...)` call.
        let src = read("SenkaniApp/Views/ContentView.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Views/ContentView.swift must exist.")
        #expect(src.contains("assembleFirstValueLayout"),
                "ContentView must define an assembleFirstValueLayout helper.")
        #expect(src.contains("FirstValueLayout.assemble"),
                "assembleFirstValueLayout must call FirstValueLayout.assemble.")
        // Welcome's startTask must route Ollama/Shell/Inspect through
        // the assembler (Claude flows through the launch sheet first).
        #expect(src.contains("case .ollama, .trackedShell, .inspectProject:"),
                "startTask must route Ollama/Shell/Inspect through the assembler in one branch.")
        // The Claude launch sheet's onLaunch must also flow through
        // the assembler so the first-run insight pane is added.
        let sheetWiringPresent =
            src.contains("ClaudeLaunchSheet { command in")
            && src.range(
                of: #"assembleFirstValueLayout\(for: TaskStarter\.Kind\.claude"#,
                options: .regularExpression
            ) != nil
        #expect(sheetWiringPresent,
                "ClaudeLaunchSheet's onLaunch must call assembleFirstValueLayout(for: .claude, ...).")
    }
}
