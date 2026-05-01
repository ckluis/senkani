import Testing
import Foundation

// Source-level regression guard for the LaunchCoordinator round
// (`onboarding-p0-launch-coordinator`).
//
// SenkaniTests does not depend on the SenkaniApp target, so behavioral
// tests against `LaunchCoordinator` can't run from here. Instead these
// tests scan the SwiftUI source to assert the contract:
//
//   - `LaunchCoordinator` exists and exposes `launchPane(...)`.
//   - No SwiftUI View calls `workspace.addPane(...)` directly.
//   - The four UI launch paths (Welcome, AddPaneSheet, Sidebar Claude,
//     CommandPalette) and the pane IPC `.add` action all funnel
//     through the coordinator.
//
// This is the explicit "source-level guard" the round's acceptance
// criteria called for.

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

/// Strip `//` and `///` line comments so substring scans don't get
/// confused by call-shape examples in doc comments. (Block comments
/// `/* ... */` are not stripped — none of the matched substrings
/// appear inside one in this codebase.)
private func stripLineComments(_ src: String) -> String {
    src.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        if trimmed.hasPrefix("//") { return "" }
        return String(line)
    }.joined(separator: "\n")
}

private func swiftFiles(under rel: String) -> [String] {
    let dir = (repoRoot as NSString).appendingPathComponent(rel)
    let url = URL(fileURLWithPath: dir)
    guard let walker = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    var out: [String] = []
    for case let fileURL as URL in walker where fileURL.pathExtension == "swift" {
        out.append(fileURL.path)
    }
    return out
}

@Suite("LaunchCoordinator — routing regression guards")
struct LaunchCoordinatorRoutingTests {

    @Test("LaunchCoordinator exists and exposes launchPane")
    func coordinatorExists() {
        let src = read("SenkaniApp/Services/LaunchCoordinator.swift")
        #expect(!src.isEmpty,
                "SenkaniApp/Services/LaunchCoordinator.swift must exist.")
        #expect(src.contains("final class LaunchCoordinator"),
                "LaunchCoordinator must be defined as a final class.")
        #expect(src.contains("func launchPane("),
                "LaunchCoordinator must expose a launchPane(...) method.")
        // Must perform all three side effects + workspace mutation.
        #expect(src.contains("workspace.addPane("),
                "LaunchCoordinator.launchPane must call workspace.addPane(...).")
        #expect(src.contains("HookRegistration.registerForProject"),
                "LaunchCoordinator.launchPane must register project hooks for terminal panes.")
        #expect(src.contains("sessions.startSession"),
                "LaunchCoordinator.launchPane must start a session watcher.")
        #expect(src.contains("saveWorkspace"),
                "LaunchCoordinator.launchPane must persist workspace state.")
    }

    @Test("No SwiftUI View calls workspace.addPane directly")
    func noDirectWorkspaceAddPaneFromViews() {
        // The model file itself defines `func addPane(...)`. Only the
        // model + the coordinator are allowed to call into the model
        // mutation path. Every other Swift file under SenkaniApp/
        // (Views, Models other than WorkspaceModel, Terminal, etc.)
        // MUST go through the coordinator.
        let allowed: Set<String> = [
            "SenkaniApp/Models/WorkspaceModel.swift",
            "SenkaniApp/Services/LaunchCoordinator.swift",
        ]
        var offenders: [String] = []
        for path in swiftFiles(under: "SenkaniApp") {
            let rel = path.replacingOccurrences(
                of: repoRoot + "/", with: ""
            )
            if allowed.contains(rel) { continue }
            let body = stripLineComments(
                (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            )
            if body.contains("workspace.addPane(") {
                offenders.append(rel)
            }
        }
        #expect(offenders.isEmpty,
                "These files call workspace.addPane(...) directly — route them through LaunchCoordinator: \(offenders)")
    }

    @Test("Sidebar Claude launch routes through LaunchCoordinator")
    func sidebarClaudeRoutesThroughCoordinator() {
        let raw = read("SenkaniApp/Views/SidebarView.swift")
        #expect(raw.contains("onLaunchPane:"),
                "SidebarView must accept an onLaunchPane closure.")
        #expect(raw.contains("onLaunchPane(.terminal, \"Claude Code\""),
                "SidebarView's ClaudeLaunchSheet must invoke onLaunchPane for Claude Code launches.")
        let code = stripLineComments(raw)
        #expect(!code.contains("workspace.addPane("),
                "SidebarView must NOT call workspace.addPane(...) directly.")
    }

    @Test("ContentView wires SidebarView through LaunchCoordinator")
    func contentViewWiresSidebarToLauncher() {
        let src = read("SenkaniApp/Views/ContentView.swift")
        #expect(src.contains("LaunchCoordinator"),
                "ContentView must reference LaunchCoordinator.")
        #expect(src.contains("ensureLauncher()"),
                "ContentView must lazily construct a single LaunchCoordinator.")
        #expect(src.contains("onLaunchPane:"),
                "ContentView must pass onLaunchPane to SidebarView.")
    }

    @Test("Pane IPC .add path routes through LaunchCoordinator")
    func paneIPCAddRoutesThroughCoordinator() {
        let src = read("SenkaniApp/Views/ContentView.swift")
        // The handler is the static handlePaneCommand; its `.add`
        // case must construct a LaunchCoordinator and call
        // launchPane(...). It must not duplicate the side-effect
        // block (workspace.addPane + HookRegistration + startSession)
        // inline anymore.
        let lines = src.components(separatedBy: "\n")
        var inAddCase = false
        var caseBody = ""
        for (i, line) in lines.enumerated() {
            if line.contains("case .add:") {
                inAddCase = true
                continue
            }
            if inAddCase {
                if line.range(of: #"^\s*case\s+\."#, options: .regularExpression) != nil {
                    break
                }
                caseBody += line + "\n"
                if i == lines.count - 1 { break }
            }
        }
        #expect(caseBody.contains("LaunchCoordinator("),
                "Pane IPC .add must construct a LaunchCoordinator.")
        #expect(caseBody.contains("launchPane("),
                "Pane IPC .add must call coord.launchPane(...).")
        #expect(!caseBody.contains("workspace.addPane("),
                "Pane IPC .add must not call workspace.addPane(...) directly anymore.")
    }

    @Test("Welcome / AddPaneSheet / CommandPalette callbacks reach the coordinator")
    func uiCallbacksReachCoordinator() {
        let src = read("SenkaniApp/Views/ContentView.swift")
        // The AddPaneSheet, WelcomeView and CommandPalette callbacks
        // funnel through the private `addPane(...)` shim, which must
        // call into the LaunchCoordinator (not workspace.addPane).
        // We confirm the shim's body delegates to ensureLauncher().
        // A regex pinned to the function header keeps this guard
        // tolerant of formatting changes.
        let pattern = #"private func addPane\(type: PaneType[^}]*ensureLauncher\(\)\.launchPane"#
        let range = src.range(of: pattern, options: .regularExpression)
        #expect(range != nil,
                "ContentView.addPane(type:title:command:) must delegate to ensureLauncher().launchPane(...)")

        // And the three UI callers still exist and reach the shim.
        #expect(src.contains("AddPaneSheet { type, title, command in"),
                "AddPaneSheet callback must be present.")
        #expect(src.contains("addPaneByTypeId(typeId)"),
                "CommandPalette callback must be present.")
        #expect(src.contains("WelcomeView("),
                "WelcomeView must be wired in ContentView.")
    }
}
