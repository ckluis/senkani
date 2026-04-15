import SwiftUI
import AppKit
import SwiftTerm

extension Notification.Name {
    static let senkaniSendBroadcast = Notification.Name("senkaniSendBroadcast")
}

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
    var onProcessStarted: ((pid_t) -> Void)?

    // Deferred shell start — set in makeNSView, executed in viewDidMoveToWindow
    struct ShellConfig {
        let path: String            // Always /bin/zsh
        let environment: [String]
        let workingDirectory: String
        let initialCommand: String  // Command to auto-type after shell starts (empty = plain shell)
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

        // Listen for broadcast messages
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBroadcast(_:)),
            name: .senkaniSendBroadcast,
            object: nil
        )
    }

    @objc private func handleBroadcast(_ notification: Notification) {
        guard let text = notification.object as? String else { return }
        terminalView?.send(txt: text)
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

        // Always start /bin/zsh as a login shell
        tv.startProcess(
            executable: config.path,
            args: [],
            environment: config.environment,
            execName: "-zsh",  // leading dash = login shell
            currentDirectory: config.workingDirectory
        )

        // If there's an initial command, send it after the shell profile loads
        if !config.initialCommand.isEmpty {
            let cmd = config.initialCommand
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak tv] in
                tv?.send(txt: cmd + "\n")
            }
        }

        // Give terminal keyboard focus
        win.makeFirstResponder(tv)

        // Report the PID back to the pane model
        let pid = tv.process?.shellPid ?? 0
        if pid > 0 {
            onProcessStarted?(pid)
        }

        print("[TERM] STARTED: shell=\(config.path) pid=\(pid) initialCommand=\(config.initialCommand) bounds=\(bounds)")
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
    let initialCommand: String
    let environment: [String: String]
    let workingDirectory: String
    let isActive: Bool
    var fontSize: CGFloat = 12
    let onProcessExited: ((Int32) -> Void)?
    let onProcessStarted: ((pid_t) -> Void)?
    let onActivate: (() -> Void)?

    init(paneId: UUID = UUID(),
         initialCommand: String = "",
         environment: [String: String] = [:],
         workingDirectory: String = NSHomeDirectory(),
         isActive: Bool = true,
         fontSize: CGFloat = 12,
         onProcessExited: ((Int32) -> Void)? = nil,
         onProcessStarted: ((pid_t) -> Void)? = nil,
         onActivate: (() -> Void)? = nil) {
        self.paneId = paneId
        self.initialCommand = initialCommand
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.isActive = isActive
        self.fontSize = fontSize
        self.onProcessExited = onProcessExited
        self.onProcessStarted = onProcessStarted
        self.onActivate = onActivate
    }

    func makeNSView(context: Context) -> FocusableTerminalView {
        let container = FocusableTerminalView()
        container.wantsLayer = true
        container.onActivate = onActivate
        container.onProcessStarted = onProcessStarted

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

        container.shellConfig = FocusableTerminalView.ShellConfig(
            path: "/bin/zsh",
            environment: env.map { "\($0.key)=\($0.value)" },
            workingDirectory: workingDirectory,
            initialCommand: initialCommand
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
        // Apply font size changes from display settings
        if let tv = nsView.terminalView {
            let currentSize = tv.font.pointSize
            if abs(currentSize - fontSize) > 0.5 {
                tv.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
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
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}
