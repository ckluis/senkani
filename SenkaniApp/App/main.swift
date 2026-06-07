import Foundation
import MCPServer
import Core
import SwiftUI
import HookRelay
import BrowserPane

// Raise RLIMIT_NOFILE before any subsystem opens fds. macOS apps launched
// via LaunchServices inherit launchd's 256 soft cap, which a recursive
// index pass can exhaust — triggering EMFILE on the next system asset
// load (e.g. CoreAnimation's default.metallib). Closes
// senkani-app-emfile-crash-during-pane-launch-2026-05-15.
raiseFileDescriptorLimit()

// U.2b-1b-6 — register the off-screen WKWebView BrowserPaneRunner with
// the Core-side BrowserDispatchRegistry so MCP / CLI callers asking for
// dispatch:"headless" find it. Done before either branch (GUI / MCP /
// socket / hook) since the registration is a cheap static-slot write and
// every host mode may need the headless arm wired.
BrowserPaneRunnerFactory.register()

let isSocketMode = CommandLine.arguments.contains("--socket-server")
let isHookMode = CommandLine.arguments.contains("--hook")
// MCP mode requires an explicit flag. The previous fallback
// (`isatty(STDIN_FILENO) == 0 → MCP`) silently switched the bundle
// into MCP-server mode whenever LaunchServices opened the .app
// (LS hands stdin=/dev/null to GUI launches), bypassing the SwiftUI
// app entirely. See incident 2026-05-10: `open SenkaniApp.app` ran
// `MCPServerRunner.run()` instead of the GUI, crashing in
// `GoBackend.walk` during warm-index. The dedicated `senkani-mcp`
// binary is what Claude Code / MCP clients register (see
// `Sources/CLI/MCPInstallCommand.swift`), so SenkaniApp doesn't need
// the implicit pipe-detect fallback.
let isMCPMode = !isSocketMode && !isHookMode
    && CommandLine.arguments.contains("--mcp-server")

if isHookMode {
    // Hook mode: act as the senkani-hook binary.
    // Reads hook event from stdin, relays to daemon socket, writes response to stdout.
    exit(HookRelay.run())
} else if isMCPMode {
    try await MCPServerRunner.run()
} else if isSocketMode {
    // Headless socket server mode -- run until terminated
    SocketServerManager.shared.hookHandler = { HookRouter.handle(eventJSON: $0) }
    SocketServerManager.shared.start()
    HookRouter.entityObserver = { KBObserver.observeHookEvent(toolName: $0, toolInput: $1) }
    // V.11b — load installed pack policy fragments at socket-server boot.
    HookRouter.refreshInstalledPacks()
    // Block forever (the socket server runs on GCD)
    dispatchMain()
} else {
    // CRITICAL: When launched from the command line (.build/release/SenkaniApp),
    // macOS treats the process as a CLI tool that can't receive keyboard events.
    // Setting the activation policy to .regular makes it a proper GUI app.
    NSApplication.shared.setActivationPolicy(.regular)
    SenkaniGUI.main()
}
