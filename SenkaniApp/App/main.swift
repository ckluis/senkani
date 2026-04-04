import Foundation
import MCPServer
import SwiftUI

let isMCPMode = CommandLine.arguments.contains("--mcp-server")
    || isatty(STDIN_FILENO) == 0  // stdin is a pipe

if isMCPMode {
    try await MCPServerRunner.run()
} else {
    SenkaniGUI.main()
}
