import SwiftUI
import AppKit
import SwiftTerm

/// Wraps SwiftTerm's LocalProcessTerminalView for use in SwiftUI.
struct TerminalViewRepresentable: NSViewRepresentable {
    let shellPath: String
    let environment: [String: String]
    let workingDirectory: String
    let isActive: Bool
    let onProcessExited: ((Int32) -> Void)?

    init(shellPath: String = "/bin/zsh",
         environment: [String: String] = [:],
         workingDirectory: String = NSHomeDirectory(),
         isActive: Bool = true,
         onProcessExited: ((Int32) -> Void)? = nil) {
        self.shellPath = shellPath
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.isActive = isActive
        self.onProcessExited = onProcessExited
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminalView.processDelegate = context.coordinator
        terminalView.nativeBackgroundColor = .black
        terminalView.nativeForegroundColor = .white

        // Build environment: inherit current + add our overrides
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Start the shell process with working directory
        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: envPairs,
            execName: (shellPath as NSString).lastPathComponent,
            currentDirectory: workingDirectory
        )

        // Request keyboard focus after the view is fully added to the hierarchy.
        // Two-tick delay ensures the window is ready.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = terminalView.window {
                window.makeFirstResponder(terminalView)
            }
        }

        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        // Only claim focus when this pane is the active one
        if isActive, nsView.window?.firstResponder !== nsView {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExited: onProcessExited)
    }

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExited: ((Int32) -> Void)?

        init(onProcessExited: ((Int32) -> Void)?) {
            self.onProcessExited = onProcessExited
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessExited?(exitCode ?? -1)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            // SwiftTerm handles resize internally
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            // Could update pane title
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // Could track cwd
        }
    }
}
