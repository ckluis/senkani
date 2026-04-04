import AppKit
import SwiftTerm

/// Manages terminal views that live OUTSIDE SwiftUI's view hierarchy
/// but are positioned to appear inside pane containers.
///
/// SwiftUI's NSHostingView consumes keyboard events before they reach
/// embedded NSViews. The portal pattern solves this by adding terminals
/// directly to the window's contentView overlay layer, then positioning
/// them to match the SwiftUI pane's frame.
@MainActor
class TerminalPortalManager {
    nonisolated(unsafe) static let shared = TerminalPortalManager()

    /// Active portals keyed by pane ID
    private var portals: [UUID: TerminalPortal] = [:]

    /// Create a terminal portal for a pane
    func createPortal(
        id: UUID,
        shellPath: String,
        environment: [String: String],
        workingDirectory: String,
        onProcessExited: ((Int32) -> Void)?
    ) -> TerminalPortal {
        // Clean up existing portal if any
        portals[id]?.teardown()

        let portal = TerminalPortal(
            id: id,
            shellPath: shellPath,
            environment: environment,
            workingDirectory: workingDirectory,
            onProcessExited: onProcessExited
        )
        portals[id] = portal
        return portal
    }

    /// Remove a portal
    func removePortal(id: UUID) {
        portals[id]?.teardown()
        portals.removeValue(forKey: id)
    }

    /// Get an existing portal
    func portal(for id: UUID) -> TerminalPortal? {
        portals[id]
    }
}

/// A single terminal portal — owns the LocalProcessTerminalView and
/// manages its lifecycle outside SwiftUI.
@MainActor
class TerminalPortal {
    let id: UUID
    let terminalView: LocalProcessTerminalView
    private let delegate: TerminalDelegate
    private var isAttached = false

    init(id: UUID,
         shellPath: String,
         environment: [String: String],
         workingDirectory: String,
         onProcessExited: ((Int32) -> Void)?) {

        self.id = id
        self.delegate = TerminalDelegate(onProcessExited: onProcessExited)

        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.autoresizingMask = []  // We manage the frame manually
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.processDelegate = delegate
        // NEVER set terminalDelegate — breaks keyboard input
        self.terminalView = tv

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
    }

    /// Attach the terminal to a window's content view
    func attach(to window: NSWindow) {
        guard !isAttached else { return }
        // Add directly to the window's contentView — NOT through SwiftUI
        window.contentView?.addSubview(terminalView)
        isAttached = true
    }

    /// Update the terminal's position and size to match the pane frame
    func updateFrame(_ frame: NSRect) {
        terminalView.frame = frame
    }

    /// Give keyboard focus to this terminal
    func focus() {
        terminalView.window?.makeFirstResponder(terminalView)
    }

    /// Remove from the window
    func teardown() {
        terminalView.removeFromSuperview()
        isAttached = false
    }
}

// MARK: - Delegate

private class TerminalDelegate: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
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
