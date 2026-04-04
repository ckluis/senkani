import SwiftUI
import AppKit
import SwiftTerm

/// Hosts SwiftTerm's LocalProcessTerminalView via NSViewControllerRepresentable.
///
/// Using a view controller (not just NSViewRepresentable) gives us proper
/// lifecycle management and responder chain integration with SwiftUI.
struct TerminalViewRepresentable: NSViewControllerRepresentable {
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

    func makeNSViewController(context: Context) -> TerminalViewController {
        let vc = TerminalViewController()
        vc.shellPath = shellPath
        vc.environment = environment
        vc.workingDirectory = workingDirectory
        vc.onProcessExited = onProcessExited
        vc.onActivate = onActivate
        return vc
    }

    func updateNSViewController(_ vc: TerminalViewController, context: Context) {
        if isActive {
            vc.requestFocus()
        }
    }
}

// MARK: - TerminalViewController

/// NSViewController that owns the LocalProcessTerminalView.
/// This gives us full control over the view lifecycle, first responder
/// management, and the responder chain — things that are hard to manage
/// from NSViewRepresentable alone.
final class TerminalViewController: NSViewController, @preconcurrency LocalProcessTerminalViewDelegate {
    var shellPath: String = "/bin/zsh"
    var environment: [String: String] = [:]
    var workingDirectory: String = NSHomeDirectory()
    var onProcessExited: ((Int32) -> Void)?
    var onActivate: (() -> Void)?

    private var terminalView: LocalProcessTerminalView!
    private var processStarted = false

    override func loadView() {
        // The terminal IS the view — no wrapper, no container
        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.processDelegate = self
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        self.terminalView = tv
        self.view = tv
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startShellIfNeeded()
        // Give the window a moment to settle, then grab focus
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.requestFocus()
        }
    }

    private func startShellIfNeeded() {
        guard !processStarted else { return }
        processStarted = true

        // Build environment: inherit current process env + overrides
        var env = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            env[key] = value
        }
        let envPairs = env.map { "\($0.key)=\($0.value)" }

        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: envPairs,
            execName: (shellPath as NSString).lastPathComponent,
            currentDirectory: workingDirectory
        )
    }

    func requestFocus() {
        guard let window = view.window else { return }
        window.makeFirstResponder(terminalView)
    }

    // MARK: - Mouse handling for pane activation

    override func mouseDown(with event: NSEvent) {
        onActivate?()
        // CRITICAL: call super so the terminal gets the event
        super.mouseDown(with: event)
        // Also explicitly request focus
        requestFocus()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        onProcessExited?(exitCode ?? -1)
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
}
