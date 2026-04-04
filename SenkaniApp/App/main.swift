import Foundation
import MCPServer
import SwiftUI

let isMCPMode = CommandLine.arguments.contains("--mcp-server")
    || isatty(STDIN_FILENO) == 0  // stdin is a pipe

let isSocketMode = CommandLine.arguments.contains("--socket-server")

if isMCPMode {
    try await MCPServerRunner.run()
} else if isSocketMode {
    // Headless socket server mode -- run until terminated
    SocketServerManager.shared.start()
    // Block forever (the socket server runs on GCD)
    dispatchMain()
} else {
    SenkaniGUI.main()
}
