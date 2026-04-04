import SwiftUI
import AppKit
import SwiftTerm

// MARK: - FocusableTerminalView (cmux pattern)

/// Intermediate NSView that bridges SwiftUI's responder chain to SwiftTerm.
/// Pattern proven by cmux (manaflow-ai/cmux).
///
/// CRITICAL requirements for SwiftTerm in SwiftUI:
/// 1. Use autoresizingMask, NOT Auto Layout
/// 2. Only set processDelegate, NEVER terminalDelegate
/// 3. FocusableTerminalView accepts focus and forwards to terminal
/// 4. App must call NSApp.setActivationPolicy(.regular) — see main.swift
class FocusableTerminalView: NSView {
    var terminalView: LocalProcessTerminalView?
    var onActivate: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        if let tv = terminalView {
            DispatchQueue.main.async {
                self.window?.makeFirstResponder(tv)
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
        }
        // Forward to terminal
        terminalView?.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        if let tv = terminalView, bounds.width > 0, bounds.height > 0 {
            tv.setFrameSize(bounds.size)
        }
    }
}

// MARK: - SwiftUI Bridge

/// Embeds SwiftTerm's LocalProcessTerminalView directly in SwiftUI
/// via NSViewRepresentable + FocusableTerminalView container.
///
/// This is the SAME approach cmux uses. It works because:
/// - setActivationPolicy(.regular) in main.swift makes the app a proper GUI app
/// - FocusableTerminalView bridges the responder chain
/// - autoresizingMask (not Auto Layout) is used for sizing
/// - Only processDelegate is set (terminalDelegate breaks input)
struct TerminalViewRepresentable: NSViewRepresentable {
    let paneId: UUID
    let shellPath: String
    let environment: [String: String]
    let workingDirectory: String
    let isActive: Bool
    let onProcessExited: ((Int32) -> Void)?
    let onActivate: (() -> Void)?

    init(paneId: UUID = UUID(),
         shellPath: String = "/bin/zsh",
         environment: [String: String] = [:],
         workingDirectory: String = NSHomeDirectory(),
         isActive: Bool = true,
         onProcessExited: ((Int32) -> Void)? = nil,
         onActivate: (() -> Void)? = nil) {
        self.paneId = paneId
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

        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black

        // CRITICAL: Only processDelegate. NEVER terminalDelegate.
        tv.processDelegate = context.coordinator

        container.addSubview(tv)
        container.terminalView = tv

        // Start shell
        let shell = shellPath.isEmpty ? "/bin/zsh" : shellPath
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        env["TERM"] = "xterm-256color"
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        tv.startProcess(
            executable: shell,
            args: [],
            environment: envPairs,
            execName: "-" + (shell as NSString).lastPathComponent
        )

        // Delayed focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            container.window?.makeFirstResponder(tv)
        }

        return container
    }

    func updateNSView(_ nsView: FocusableTerminalView, context: Context) {
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
