import Foundation
import MCPServer
import Core
import SwiftUI
import HookRelay
import BrowserPane

// Ignore SIGPIPE process-wide BEFORE any socket listener starts. The hook
// + pane listeners in SocketServerManager do raw `Darwin.write` on
// Unix-domain sockets; a write to a peer that already disconnected (e.g.
// the 5 ms hook-relay client closed before HookRouter.handle returned)
// would otherwise deliver the DEFAULT SIGPIPE and terminate this process
// TRACELESSLY — no .ips, no stderr, no jetsam, no unified-log entry. With
// SIGPIPE ignored the write fails with EPIPE (already discarded by every
// raw-socket writer here) and the process lives. Placed before the
// GUI/socket/hook/mcp branch dispatch so it covers every host mode this
// binary runs as. Closes
// t6-banner-walk-app-exits-traceless-on-claude-pane-prompt-2026-06-22.
ignoreBrokenPipeSignal()

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

// U.2b-2 GUI child a-1 — register the VISIBLE-pane runner factory so
// `dispatch: .pane` stops fail-closed-refusing when this app is running.
// Mirrors the `register()` (headless) call above; writes only the Core
// `_paneFactory` slot via `BrowserDispatchRegistry.registerPaneRunnerFactory`,
// leaving the headless slot untouched. Constructs a `.visiblePane` runner
// bound to whatever live pane `BrowserPaneView` publishes into
// `LivePaneRegistry`. This registration lives in the SenkaniApp binary
// only — the standalone CLI / `senkani-mcp` binaries never link SenkaniApp,
// so `.pane` stays fail-closed there (no SwiftUI is pulled in).
BrowserPaneRunnerFactory.registerPaneRunner()

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
