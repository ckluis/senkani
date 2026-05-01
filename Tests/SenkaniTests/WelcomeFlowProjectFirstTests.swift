import Testing
import Foundation

// Source-level regression guard for `onboarding-p0-project-first-welcome`.
//
// SenkaniTests does not link the SenkaniApp target, so behavioral
// SwiftUI tests can't run from here. Instead these tests scan the
// Welcome / ContentView / PaneContainerView sources to assert the
// contracts the round shipped:
//
//   - WelcomeView accepts a workspace + a project-chooser callback.
//   - The Claude and Ollama agent cards on the Welcome surface are
//     gated behind a chosen project (`projects.isEmpty` blocks them).
//   - Plain Shell remains an explicit escape hatch and names the
//     directory it will run in (no silent ~ launch).
//   - Welcome agent-card titles use the verb-first
//     "Start Claude in <project>" shape, not the prior
//     "Full compression pipeline + MCP integration" marketing copy.
//   - ContentView wires the project chooser to NSOpenPanel +
//     `workspace.addProject(...)`.
//   - PaneContainerView's terminal context label uses
//     `pane.workingDirectory`, not the always-empty `previewFilePath`.

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

@Suite("Onboarding P0 — project-first Welcome flow")
struct WelcomeFlowProjectFirstTests {

    @Test("WelcomeView accepts workspace + onChooseProject callback")
    func welcomeViewAcceptsProjectChooser() {
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        #expect(!raw.isEmpty,
                "WelcomeView source must exist.")
        #expect(raw.contains("let workspace: WorkspaceModel"),
                "WelcomeView must take a WorkspaceModel so it can read project state for its launch gate.")
        #expect(raw.contains("let onChooseProject:"),
                "WelcomeView must take an onChooseProject closure for the project chooser button.")
    }

    @Test("WelcomeView gates Claude + Ollama on a chosen project")
    func welcomeViewGatesAgentLaunches() {
        // Project-gate shape after the P1 task-starter round:
        // `TaskStarter.requiresProject` is the catalog-level gate;
        // `TaskStarterCard.available` enforces it via
        // `requiresProject && !hasProject`. WelcomeView still derives
        // hasProject from `workspace.projects.isEmpty` so the source-
        // level marker is unchanged.
        let welcome = stripLineComments(read("SenkaniApp/Views/WelcomeView.swift"))
        let catalog = stripLineComments(read("Sources/Core/TaskStarterCatalog.swift"))
        #expect(welcome.contains("workspace.projects.isEmpty"),
                "WelcomeView must derive its project gate from workspace.projects.isEmpty.")
        #expect(welcome.contains("starter.requiresProject && !hasProject"),
                "TaskStarterCard.available must gate project-required starters on hasProject.")
        // Catalog-level: Claude + Ollama both demand a project.
        let claudeBlock = catalog.components(separatedBy: #"id: "ask-claude""#)
        let ollamaBlock = catalog.components(separatedBy: #"id: "use-ollama""#)
        #expect(claudeBlock.count >= 2,
                "Catalog must define an `ask-claude` starter.")
        #expect(ollamaBlock.count >= 2,
                "Catalog must define a `use-ollama` starter.")
        if claudeBlock.count >= 2 {
            let body = claudeBlock[1].prefix(400)
            #expect(body.contains("requiresProject: true"),
                    "ask-claude starter must set requiresProject: true.")
        }
        if ollamaBlock.count >= 2 {
            let body = ollamaBlock[1].prefix(400)
            #expect(body.contains("requiresProject: true"),
                    "use-ollama starter must set requiresProject: true.")
        }
    }

    @Test("Welcome agent cards use verb-first project-aware titles")
    func welcomeCopyIsVerbFirstAndProjectAware() {
        // The P0 round shipped "Start Claude in" / "Start Ollama in"
        // labels. The P1 task-starter round (`onboarding-p1-task-presets`)
        // moved that copy into `Sources/Core/TaskStarterCatalog.swift`
        // with outcome-first verbs ("Ask Claude", "Use Ollama") and a
        // project-aware suffix added at render time. Assert against the
        // catalog (the new source of truth) rather than the SwiftUI body.
        let catalog = read("Sources/Core/TaskStarterCatalog.swift")
        #expect(!catalog.isEmpty,
                "TaskStarterCatalog source must exist (P1 task-starter round).")
        #expect(catalog.contains(#"label: "Ask Claude""#),
                "Catalog must contain the verb-first 'Ask Claude' starter label.")
        #expect(catalog.contains(#"label: "Use Ollama""#),
                "Catalog must contain the verb-first 'Use Ollama' starter label.")
        // Project-aware suffix is appended at render time.
        #expect(catalog.contains(#""\(label) in \(name)""#),
                "TaskStarter.displayLabel must render the '<verb> ... in <projectName>' shape.")
        // The old marketing-copy subtitle is still gone.
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        #expect(!raw.contains("Full compression pipeline + MCP integration"),
                "The old 'Full compression pipeline + MCP integration' subtitle must remain absent.")
    }

    @Test("Plain Shell remains an explicit escape hatch and names its directory")
    func plainShellEscapeHatchIsExplicit() {
        // After the P1 task-starter round the shell card is rendered
        // from `TaskStarterCatalog`'s `open-tracked-shell` entry. Its
        // copy is the source of truth; the "in home folder" suffix is
        // appended at render time by `TaskStarter.displayLabel`.
        let catalog = read("Sources/Core/TaskStarterCatalog.swift")
        #expect(catalog.contains("home folder"),
                "TaskStarter.displayLabel must explicitly name 'home folder' so a no-project shell launch isn't silent.")
        #expect(catalog.contains(#"id: "open-tracked-shell""#),
                "Catalog must define an `open-tracked-shell` starter (the escape hatch).")
        #expect(catalog.contains(#"label: "Open a tracked shell""#),
                "Tracked-shell starter must use the verb-first 'Open a tracked shell' label.")
        #expect(catalog.contains("regular terminal Senkani is watching"),
                "Tracked-shell subtitle must describe its purpose, not marketing copy.")
        // And the starter must remain usable without a project.
        let block = catalog.components(separatedBy: #"id: "open-tracked-shell""#)
        if block.count >= 2 {
            let body = block[1].prefix(400)
            #expect(body.contains("requiresProject: false"),
                    "Tracked-shell starter must have requiresProject: false (the escape hatch).")
        }
    }

    @Test("WelcomeView surfaces a 'Choose project folder' affordance when no project")
    func welcomeShowsProjectChooser() {
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        #expect(raw.contains("Choose project folder"),
                "WelcomeView must surface a 'Choose project folder' button when no project is selected.")
        // The chooser must invoke the onChooseProject closure.
        let src = stripLineComments(raw)
        #expect(src.contains("onChooseProject()"),
                "The project-chooser affordance must invoke onChooseProject().")
    }

    @Test("ContentView wires onChooseProject to NSOpenPanel + addProject")
    func contentViewWiresProjectPicker() {
        let src = read("SenkaniApp/Views/ContentView.swift")
        #expect(src.contains("openProjectFolderPicker"),
                "ContentView must expose a project-folder-picker helper for WelcomeView.")
        #expect(src.contains("onChooseProject: openProjectFolderPicker"),
                "ContentView's WelcomeView call must wire onChooseProject to openProjectFolderPicker.")
        #expect(src.contains("workspace.addProject(path: url.path)"),
                "openProjectFolderPicker must add the chosen URL to the workspace.")
        // And it must use NSOpenPanel (the macOS folder picker).
        #expect(src.contains("NSOpenPanel()"),
                "openProjectFolderPicker must use NSOpenPanel for the directory picker.")
    }

    @Test("Terminal pane header reads pane.workingDirectory, not previewFilePath")
    func terminalHeaderUsesWorkingDirectory() {
        let raw = read("SenkaniApp/Views/PaneContainerView.swift")
        let src = stripLineComments(raw)
        // Find the .terminal case in contextLabel and confirm it
        // pulls from workingDirectory rather than previewFilePath.
        guard let caseRange = src.range(of: "case .terminal:") else {
            Issue.record("Could not find `case .terminal:` in PaneContainerView.swift contextLabel.")
            return
        }
        // Take the next ~600 chars after the case marker — enough to
        // cover the case body without bleeding into the next case.
        let tail = src[caseRange.upperBound...]
        let endIdx = tail.range(of: "case .")?.lowerBound ?? tail.endIndex
        let body = String(tail[..<endIdx])
        #expect(body.contains("pane.workingDirectory"),
                "Terminal contextLabel must read pane.workingDirectory.")
        #expect(!body.contains("pane.previewFilePath"),
                "Terminal contextLabel must NOT fall back to pane.previewFilePath (it's empty for terminals and shows a bogus '~').")
    }

    @Test("Manual-log queues a real-machine first-run check for the project gate")
    func manualLogQueuesFirstRunCheck() {
        let log = read("tools/soak/manual-log.md")
        #expect(!log.isEmpty,
                "tools/soak/manual-log.md must exist.")
        #expect(log.contains("onboarding-p0-project-first-welcome"),
                "manual-log must queue a real-machine check for onboarding-p0-project-first-welcome.")
    }
}
