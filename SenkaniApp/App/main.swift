import Foundation
import MCPServer
import Core
import SwiftUI

let isMCPMode = CommandLine.arguments.contains("--mcp-server")
    || isatty(STDIN_FILENO) == 0  // stdin is a pipe

let isSocketMode = CommandLine.arguments.contains("--socket-server")
let isHookMode = CommandLine.arguments.contains("--hook")

if isHookMode {
    // Hook mode: act as the senkani-hook binary.
    // Reads hook event from stdin, relays to daemon socket, writes response to stdout.
    exit(HookMain.run())
} else if isMCPMode {
    try await MCPServerRunner.run()
} else if isSocketMode {
    // Headless socket server mode -- run until terminated
    SocketServerManager.shared.hookHandler = { HookRouter.handle(eventJSON: $0) }
    SocketServerManager.shared.start()
    // Block forever (the socket server runs on GCD)
    dispatchMain()
} else {
    // CRITICAL: When launched from the command line (.build/release/SenkaniApp),
    // macOS treats the process as a CLI tool that can't receive keyboard events.
    // Setting the activation policy to .regular makes it a proper GUI app.
    NSApplication.shared.setActivationPolicy(.regular)
    SenkaniGUI.main()
}
