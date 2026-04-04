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
    let onActivate: (() -> Void)?

    init(shellPath: String = "/bin/zsh",
         environment: [String: String] = [:],
         workingDirectory: String = NSHomeDirectory(),
         isActive: Bool = true,
         onProcessExited: ((Int32) -> Void)? = nil,
         onActivate: (() -> Void)? = nil) {
        self.shellPath = shellPath
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.isActive = isActive
        self.onProcessExited = onProcessExited
        self.onActivate = onActivate
    }

    func makeNSView(context: Context) -> ActivatableTerminalView {
        let terminal = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        terminal.processDelegate = context.coordinator
        terminal.nativeBackgroundColor = .black
        terminal.nativeForegroundColor = .white

        let wrapper = ActivatableTerminalView(frame: .zero, terminal: terminal)
        wrapper.onActivate = context.coordinator.onActivate

        // Build environment: inherit current + add our overrides
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        // Start the shell process
        terminal.startProcess(
            executable: shellPath,
            args: [],
            environment: envPairs,
            execName: (shellPath as NSString).lastPathComponent,
            currentDirectory: workingDirectory
        )

        // Request keyboard focus after the view is in the hierarchy
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let window = terminal.window {
                window.makeFirstResponder(terminal)
            }
        }

        return wrapper
    }

    func updateNSView(_ nsView: ActivatableTerminalView, context: Context) {
        // Only claim focus when this pane is the active one
        let terminal = nsView.terminalView
        if isActive, nsView.window?.firstResponder !== terminal {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(terminal)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExited: onProcessExited, onActivate: onActivate)
    }

    typealias NSViewType = ActivatableTerminalView

    class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let onProcessExited: ((Int32) -> Void)?
        let onActivate: (() -> Void)?

        init(onProcessExited: ((Int32) -> Void)?, onActivate: (() -> Void)?) {
            self.onProcessExited = onProcessExited
            self.onActivate = onActivate
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

// MARK: - ActivatableTerminalView

/// Wrapper NSView that hosts a LocalProcessTerminalView and catches
/// mouse clicks to notify the parent pane, without subclassing
/// (LocalProcessTerminalView members aren't open for override).
class ActivatableTerminalView: NSView {
    let terminalView: LocalProcessTerminalView
    var onActivate: (() -> Void)?

    init(frame: NSRect, terminal: LocalProcessTerminalView) {
        self.terminalView = terminal
        super.init(frame: frame)
        addSubview(terminal)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        // Forward to the terminal so it gets the click
        terminalView.mouseDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // Delegate focus to the actual terminal
        return window?.makeFirstResponder(terminalView) ?? false
    }
}
