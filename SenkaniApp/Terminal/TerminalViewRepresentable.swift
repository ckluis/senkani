import SwiftUI
import AppKit
import SwiftTerm

// MARK: - FocusableTerminalView

/// Container NSView that bridges SwiftUI's responder chain to SwiftTerm.
///
/// CRITICAL LESSON: startProcess must be called AFTER the view is in a window.
/// In NSViewRepresentable, makeNSView returns BEFORE SwiftUI adds the view
/// to its hierarchy. Calling startProcess in makeNSView means the terminal
/// has no window, no real frame, and the PTY initializes incorrectly.
///
/// Solution: defer startProcess to viewDidMoveToWindow(), which fires
/// when AppKit actually adds the view to the window hierarchy.
class FocusableTerminalView: NSView {
    var terminalView: LocalProcessTerminalView?
    var onActivate: (() -> Void)?

    // Deferred shell start — set in makeNSView, executed in viewDidMoveToWindow
    struct ShellConfig {
        let path: String       // Always an absolute path (e.g. /bin/zsh)
        let args: [String]     // e.g. ["-c", "claude"] for non-shell commands
        let environment: [String]
        let workingDirectory: String
    }
    var shellConfig: ShellConfig?
    private var processStarted = false

    override var acceptsFirstResponder: Bool { true }

    // Called by AppKit when this view is added to a window hierarchy.
    // THIS is when we start the shell — not before.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        print("[TERM] viewDidMoveToWindow fired, window=\(String(describing: window)), bounds=\(bounds)")
        startProcessIfReady()
    }

    override func layout() {
        super.layout()
        // Resize terminal to fill container
        if let tv = terminalView, bounds.width > 0, bounds.height > 0 {
            tv.setFrameSize(bounds.size)
        }
        // Also try starting process here — layout gives us real dimensions
        startProcessIfReady()
    }

    private func startProcessIfReady() {
        print("[TERM] startProcessIfReady: started=\(processStarted) window=\(window != nil) bounds=\(bounds)")
        // ALL conditions must be true:
        // 1. Not already started
        // 2. Shell config is set
        // 3. Terminal view exists
        // 4. We're in a window
        // 5. We have real dimensions (not zero)
        guard !processStarted,
              let config = shellConfig,
              let tv = terminalView,
              let win = window,
              bounds.width > 10, bounds.height > 10
        else { return }

        processStarted = true

        // Ensure terminal has our dimensions before starting
        tv.setFrameSize(bounds.size)

        let execName = config.args.isEmpty
            ? "-" + (config.path as NSString).lastPathComponent  // login shell
            : (config.path as NSString).lastPathComponent

        tv.startProcess(
            executable: config.path,
            args: config.args,
            environment: config.environment,
            execName: execName,
            currentDirectory: config.workingDirectory
        )

        // Give terminal keyboard focus
        let frResult = win.makeFirstResponder(tv)

        // Diagnostics
        print("[TERM] PROCESS STARTED: executable=\(config.path) args=\(config.args)")
        print("[TERM] terminal frame=\(tv.frame) bounds=\(tv.bounds)")
        print("[TERM] terminal rows=\(tv.getTerminal().rows) cols=\(tv.getTerminal().cols)")
        print("[TERM] terminal fgColor=\(tv.nativeForegroundColor) bgColor=\(tv.nativeBackgroundColor)")
        print("[TERM] terminal font=\(String(describing: tv.font))")
        print("[TERM] makeFirstResponder result=\(frResult)")
        print("[TERM] window.firstResponder=\(String(describing: win.firstResponder))")
        print("[TERM] terminal.acceptsFirstResponder=\(tv.acceptsFirstResponder)")
        print("[TERM] terminal isHidden=\(tv.isHidden) alphaValue=\(tv.alphaValue)")
        print("[TERM] terminal superview=\(String(describing: tv.superview))")
        print("[TERM] container superview=\(String(describing: self.superview))")
    }

    override func becomeFirstResponder() -> Bool {
        // When SwiftUI gives us focus, forward to the actual terminal
        if let tv = terminalView {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(tv)
            }
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        if let tv = terminalView {
            window?.makeFirstResponder(tv)
        }
        // MUST call super — propagates through AppKit responder chain.
        // Calling terminalView?.mouseDown directly bypasses this.
        super.mouseDown(with: event)
    }
}

// MARK: - SwiftUI Bridge

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

        // Colors
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = .black

        // Font — both Flock and cmux set this explicitly
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        // CRITICAL: Only processDelegate. NEVER terminalDelegate.
        tv.processDelegate = context.coordinator

        // Add terminal to container
        container.addSubview(tv)
        container.terminalView = tv

        // DO NOT call startProcess here.
        // makeNSView returns BEFORE the view is in a window.
        // Flock adds the terminal to clipView (already in window) THEN calls startProcess.
        // We must wait for viewDidMoveToWindow.

        // Prepare shell config for deferred start
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        env["TERM"] = "xterm-256color"
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // Determine executable path and args.
        // SwiftTerm's startProcess needs an absolute path — it doesn't search PATH.
        // For shell paths like "/bin/zsh", run directly as a login shell.
        // For commands like "claude" or "ollama run llama3", run via /bin/zsh -c.
        let command = shellPath.isEmpty ? "/bin/zsh" : shellPath
        let shellExe: String
        let shellArgs: [String]

        if command.hasPrefix("/") {
            // Absolute path — run directly (login shell)
            shellExe = command
            shellArgs = []
        } else {
            // Non-absolute command — run through shell so PATH is searched
            shellExe = "/bin/zsh"
            shellArgs = ["-c", "exec \(command)"]
        }

        container.shellConfig = FocusableTerminalView.ShellConfig(
            path: shellExe,
            args: shellArgs,
            environment: envArray,
            workingDirectory: workingDirectory
        )

        return container
    }

    func updateNSView(_ nsView: FocusableTerminalView, context: Context) {
        // Only touch first responder if this pane is active AND terminal
        // isn't already the first responder (avoid thrashing)
        if isActive, let tv = nsView.terminalView,
           nsView.window?.firstResponder !== tv {
            nsView.window?.makeFirstResponder(tv)
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
