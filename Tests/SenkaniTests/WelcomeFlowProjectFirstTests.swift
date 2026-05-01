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
        let src = stripLineComments(read("SenkaniApp/Views/WelcomeView.swift"))
        // hasProject derives from workspace.projects.isEmpty, and is
        // ANDed into the Claude + Ollama AgentCard `available:` flag.
        #expect(src.contains("workspace.projects.isEmpty"),
                "WelcomeView must derive its project gate from workspace.projects.isEmpty.")
        // Both Claude and Ollama gate on hasProject (`&& hasProject`).
        let hasProjectGate = src.components(separatedBy: "&& hasProject").count - 1
        #expect(hasProjectGate >= 2,
                "Both the Claude and Ollama agent cards must gate `available:` on hasProject (saw \(hasProjectGate) gate sites).")
    }

    @Test("Welcome agent cards use verb-first project-aware titles")
    func welcomeCopyIsVerbFirstAndProjectAware() {
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        #expect(raw.contains("Start Claude in"),
                "Claude agent card title must take the verb-first 'Start Claude in <project>' shape.")
        #expect(raw.contains("Start Ollama in"),
                "Ollama agent card title must take the verb-first 'Start Ollama in <project>' shape.")
        // The old marketing-copy subtitle is gone.
        #expect(!raw.contains("Full compression pipeline + MCP integration"),
                "The old 'Full compression pipeline + MCP integration' subtitle must be replaced with project-aware copy.")
    }

    @Test("Plain Shell remains an explicit escape hatch and names its directory")
    func plainShellEscapeHatchIsExplicit() {
        let raw = read("SenkaniApp/Views/WelcomeView.swift")
        // Plain Shell stays available even without a project — but it
        // must name the directory so a user clicking it has chosen
        // the home-folder destination explicitly.
        #expect(raw.contains("home folder"),
                "Plain Shell card must explicitly name 'home folder' so a no-project launch isn't silent.")
        #expect(raw.contains("Tracked terminal"),
                "Plain Shell card must describe itself as a tracked terminal — its purpose, not marketing copy.")
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
