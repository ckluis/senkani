import SwiftUI
import AppKit
import SwiftTerm

// MARK: - FocusableTerminalView (the key to making this work)

/// Intermediate NSView container that bridges SwiftUI's responder chain
/// to SwiftTerm's LocalProcessTerminalView.
///
/// Pattern from cmux (manaflow-ai/cmux): SwiftUI can't directly manage
/// first responder for AppKit subviews. This container accepts focus from
/// SwiftUI and forwards it to the actual terminal.
///
/// CRITICAL: Use autoresizingMask, NOT Auto Layout. SwiftTerm's
/// LocalProcessTerminalView doesn't work correctly with NSLayoutConstraint.
class FocusableTerminalView: NSView {
    var terminalView: LocalProcessTerminalView?
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        // When SwiftUI gives us focus, forward to the actual terminal
        if let tv = terminalView {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(tv)
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        // Explicitly request focus for the terminal on click
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        // Resize the terminal to fill the container
        if let tv = terminalView, bounds.size.width > 0, bounds.size.height > 0 {
            tv.setFrameSize(bounds.size)
        }
    }
}

// MARK: - SwiftUI Bridge

/// Hosts SwiftTerm's LocalProcessTerminalView in SwiftUI via the
/// FocusableTerminalView container pattern.
///
/// IMPORTANT: Only set processDelegate on the terminal, NEVER
/// terminalDelegate — setting terminalDelegate breaks keyboard input
/// in SwiftUI contexts (discovered by cmux project).
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

    func makeNSView(context: Context) -> FocusableTerminalView {
        let container = FocusableTerminalView()
        container.wantsLayer = true
        container.onActivate = onActivate

        let tv = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // CRITICAL: autoresizingMask, NOT Auto Layout
        tv.autoresizingMask = [.width, .height]

        // Colors
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black

        // CRITICAL: Only processDelegate. NEVER set terminalDelegate —
        // it breaks keyboard input in SwiftUI hosting contexts.
        tv.processDelegate = context.coordinator

        container.addSubview(tv)
        container.terminalView = tv

        // Start the shell process
        let shell = shellPath.isEmpty ? "/bin/zsh" : shellPath
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        tv.startProcess(
            executable: shell,
            args: [],
            environment: envPairs,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // Delayed first responder — window hierarchy must be established first
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            container.window?.makeFirstResponder(tv)
        }

        return container
    }

    func updateNSView(_ nsView: FocusableTerminalView, context: Context) {
        // Re-establish first responder every time SwiftUI updates this view
        // (tab switch, pane activation, etc.)
        if isActive {
            DispatchQueue.main.async {
                if let tv = nsView.terminalView {
                    nsView.window?.makeFirstResponder(tv)
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProcessExited: onProcessExited)
    }

    class Coordinator: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
        let onProcessExited: ((Int32) -> Void)?

        init(onProcessExited: ((Int32) -> Void)?) {
            self.onProcessExited = onProcessExited
        }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            onProcessExited?(exitCode ?? -1)
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
