import Testing
import Foundation
@testable import Core

// Unit + source-level guards for `onboarding-p1-task-presets`.
//
// Behavioral coverage of `TaskStarterCatalog` (Core target — directly
// linkable from tests) plus source-level scans of the Welcome /
// ContentView wiring. The latter mirrors the pattern used by
// `WelcomeFlowProjectFirstTests` and `LaunchCoordinatorRoutingTests`
// because SenkaniTests does not link the SenkaniApp target.

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

private func stripLineComments(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("//") { return "" }
        return String(line)
    }.joined(separator: "\n")
}

@Suite("Onboarding P1 — task-starter catalog")
struct TaskStarterCatalogTests {

    // MARK: - Catalog shape

    @Test("Catalog ships exactly four task starters in canonical order")
    func canonicalOrder() {
        let ids = TaskStarterCatalog.all().map(\.id)
        #expect(ids == [
            "ask-claude",
            "use-ollama",
            "open-tracked-shell",
            "inspect-project",
        ],
        "Welcome's first-run IA depends on this exact 4-entry order. Adding a starter is a Luminary-grade decision — see Sources/Core/TaskStarterCatalog.swift. Got: \(ids)")
    }

    @Test("Every starter has non-empty label, subtitle, icon, and a real pane mapping")
    func everyStarterIsRenderable() {
        let panes = Set(PaneGalleryBuilder.allEntries().map(\.id))
        for starter in TaskStarterCatalog.all() {
            #expect(!starter.label.isEmpty,
                    "Starter '\(starter.id)' must have a label.")
            #expect(!starter.subtitle.isEmpty,
                    "Starter '\(starter.id)' must have a subtitle.")
            #expect(!starter.icon.isEmpty,
                    "Starter '\(starter.id)' must have an SF Symbol icon.")
            #expect(panes.contains(starter.paneTypeID),
                    "Starter '\(starter.id)' resolves to paneTypeID '\(starter.paneTypeID)' which is not in PaneGalleryBuilder.")
        }
    }

    @Test("Each kind is used at most once — no two starters resolve to the same launch")
    func kindsAreUnique() {
        let kinds = TaskStarterCatalog.all().map(\.kind)
        #expect(Set(kinds.map(\.rawValue)).count == kinds.count,
                "Two starters share a launch `kind` — duplication makes the deterministic mapping ambiguous.")
    }

    // MARK: - Project gating

    @Test("Tracked shell is the only no-project escape hatch; the rest require a project")
    func trackedShellIsTheOnlyEscapeHatch() {
        let starters = TaskStarterCatalog.all()
        let shell = starters.first { $0.id == "open-tracked-shell" }
        #expect(shell?.requiresProject == false,
                "open-tracked-shell must be the no-project escape hatch (requiresProject: false).")
        for starter in starters where starter.id != "open-tracked-shell" {
            #expect(starter.requiresProject,
                    "Starter '\(starter.id)' must require a project — only the tracked shell is an escape hatch.")
        }
    }

    // MARK: - Clarity (Podmajersky)

    @Test("Labels are verb-first; subtitles never use FCSIT/MCP shorthand")
    func clarityRequirements() {
        // Verb-first: starts with a known onboarding verb. Norman-mode —
        // the user reads the label as an action, not a feature name.
        let onboardingVerbs = ["Ask", "Use", "Open", "Inspect", "Run", "Start"]
        // Forbidden shorthand the first-use surface must not surface
        // (Podmajersky synthesis — labels are the affordances).
        let forbidden = ["MCP", "FCSIT", "F/C/S/I/T", "LLM-as-judge", "OAuth", "stdin"]
        for starter in TaskStarterCatalog.all() {
            let firstWord = starter.label.split(separator: " ").first.map(String.init) ?? ""
            #expect(onboardingVerbs.contains(firstWord),
                    "Starter '\(starter.id)' label '\(starter.label)' must start with a verb (one of \(onboardingVerbs)).")
            for term in forbidden {
                #expect(!starter.label.contains(term) && !starter.subtitle.contains(term),
                        "Starter '\(starter.id)' surface contains forbidden shorthand '\(term)'.")
            }
        }
    }

    // MARK: - Project-aware rendering

    @Test("displayLabel renders '<verb> ... in <project>' when a project is given")
    func displayLabelIsProjectAware() {
        guard let claude = TaskStarterCatalog.find("ask-claude") else {
            Issue.record("ask-claude must be in the catalog.")
            return
        }
        #expect(claude.displayLabel(for: "senkani") == "Ask Claude in senkani",
                "Project-aware label must read 'Ask Claude in <project>'.")
        // Without a project the project-required starter falls back to
        // the bare verb-first label so the missing-precondition gate
        // is the visible affordance, not a misleading suffix.
        #expect(claude.displayLabel(for: nil) == "Ask Claude",
                "Without a project, the project-required starter must render the bare label.")

        guard let shell = TaskStarterCatalog.find("open-tracked-shell") else {
            Issue.record("open-tracked-shell must be in the catalog.")
            return
        }
        #expect(shell.displayLabel(for: nil) == "Open a tracked shell in home folder",
                "The tracked-shell escape hatch must explicitly name 'home folder' when no project is chosen.")
        #expect(shell.displayLabel(for: "senkani") == "Open a tracked shell in senkani",
                "With a project chosen, the tracked-shell card must run in that project.")
    }

    @Test("displaySubtitle surfaces the missing-precondition before the outcome")
    func displaySubtitlePrioritizesGate() {
        guard let inspect = TaskStarterCatalog.find("inspect-project") else {
            Issue.record("inspect-project must be in the catalog.")
            return
        }
        #expect(inspect.displaySubtitle(for: nil) == "Choose a project folder first",
                "Project-required starters must surface the missing project gate in the subtitle when no project is chosen.")
        #expect(inspect.displaySubtitle(for: "senkani") == inspect.subtitle,
                "With a project chosen, the subtitle must show the outcome description.")

        guard let shell = TaskStarterCatalog.find("open-tracked-shell") else {
            Issue.record("open-tracked-shell must be in the catalog.")
            return
        }
        #expect(shell.displaySubtitle(for: nil) == shell.subtitle,
                "The tracked-shell escape hatch must keep its outcome subtitle even without a project.")
    }

    @Test("Lookup helpers behave")
    func lookupHelpers() {
        #expect(TaskStarterCatalog.find("ask-claude") != nil)
        #expect(TaskStarterCatalog.find("nonexistent") == nil)
    }

    // MARK: - Welcome / ContentView wiring (source-level)

    @Test("WelcomeView renders task starters and demotes pane gallery one level deeper")
    func welcomeRendersStartersAndDemotesGallery() {
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        #expect(raw.contains("TaskStarterCatalog.all()"),
                "WelcomeView must iterate TaskStarterCatalog.all() to render the starter cards.")
        #expect(raw.contains("let onStartTask:"),
                "WelcomeView must accept an onStartTask callback.")
        #expect(raw.contains("let onShowAllPanes:"),
                "WelcomeView must accept an onShowAllPanes callback for the demoted full pane gallery.")
        #expect(raw.contains("Show all panes"),
                "WelcomeView must surface a 'Show all panes' affordance — the full gallery is one level deeper now.")
    }

    @Test("ContentView wires Welcome onStartTask through LaunchCoordinator and the Claude sheet")
    func contentViewWiresStartTask() {
        let src = stripLineComments(read("SenkaniApp/Views/ContentView.swift"))
        #expect(src.contains("private func startTask("),
                "ContentView must expose a startTask(_:) resolver.")
        #expect(src.contains("case .claude:") && src.contains("showClaudeLaunch = true"),
                "Claude starter must open the ClaudeLaunchSheet (deterministic mapping).")
        #expect(src.contains("case .ollama:") && src.contains("type: .ollamaLauncher"),
                "Ollama starter must launch an ollamaLauncher pane.")
        #expect(src.contains("case .trackedShell:") && src.contains("type: .terminal"),
                "Tracked-shell starter must launch a terminal pane.")
        #expect(src.contains("case .inspectProject:") && src.contains("type: .codeEditor"),
                "Inspect-project starter must launch the code editor pane.")
        #expect(src.contains("onShowAllPanes: { showAddPaneSheet = true }"),
                "ContentView must wire onShowAllPanes to the existing AddPaneSheet (the advanced path).")
    }

    @Test("Manual-log queues a 10-minute walkthrough for onboarding-p1-task-presets")
    func manualLogQueuesWalkthrough() {
        let log = read("tools/soak/manual-log.md")
        #expect(!log.isEmpty,
                "tools/soak/manual-log.md must exist.")
        #expect(log.contains("onboarding-p1-task-presets"),
                "manual-log must queue a real-machine walkthrough for onboarding-p1-task-presets.")
    }
}
