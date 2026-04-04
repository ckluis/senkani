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
        let path: String
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

        tv.startProcess(
            executable: config.path,
            args: [],
            environment: config.environment,
            execName: "-" + (config.path as NSString).lastPathComponent,
            currentDirectory: config.workingDirectory
        )

        // Give terminal keyboard focus
        win.makeFirstResponder(tv)
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
        let shell = shellPath.isEmpty ? "/bin/zsh" : shellPath
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        env["TERM"] = "xterm-256color"

        container.shellConfig = FocusableTerminalView.ShellConfig(
            path: shell,
            environment: env.map { "\($0.key)=\($0.value)" },
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
