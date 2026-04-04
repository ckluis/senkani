import AppKit
import SwiftTerm

/// Manages terminal views that each live in their own child NSWindow,
/// positioned to float over the SwiftUI pane area.
///
/// Why child windows: SwiftUI's NSHostingView consumes ALL keyboard events
/// for any NSView in its hierarchy — even subviews added directly to
/// contentView. The only proven approach is a separate NSWindow, which
/// has its own responder chain independent of SwiftUI.
@MainActor
class TerminalPortalManager {
    nonisolated(unsafe) static let shared = TerminalPortalManager()

    private var portals: [UUID: TerminalPortal] = [:]

    func createPortal(
        id: UUID,
        shellPath: String,
        environment: [String: String],
        workingDirectory: String,
        onProcessExited: ((Int32) -> Void)?
    ) -> TerminalPortal {
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

    func removePortal(id: UUID) {
        portals[id]?.teardown()
        portals.removeValue(forKey: id)
    }

    func portal(for id: UUID) -> TerminalPortal? {
        portals[id]
    }
}

/// A terminal that lives in its own borderless child NSWindow.
@MainActor
class TerminalPortal {
    let id: UUID
    let terminalView: LocalProcessTerminalView
    private let delegate: TerminalDelegate
    private var childWindow: NSWindow?
    private weak var parentWindow: NSWindow?

    init(id: UUID,
         shellPath: String,
         environment: [String: String],
         workingDirectory: String,
         onProcessExited: ((Int32) -> Void)?) {

        self.id = id
        self.delegate = TerminalDelegate(onProcessExited: onProcessExited)

        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.autoresizingMask = [.width, .height]
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.processDelegate = delegate
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

    /// Attach as a child window of the parent
    func attach(to parent: NSWindow) {
        guard childWindow == nil else { return }
        self.parentWindow = parent

        // Create a borderless, non-activating child window
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        child.isOpaque = false
        child.backgroundColor = .black
        child.hasShadow = false
        child.level = .normal
        child.contentView = terminalView
        child.isReleasedWhenClosed = false

        // Add as child — moves with parent, always on top of parent
        parent.addChildWindow(child, ordered: .above)
        child.orderFront(nil)

        self.childWindow = child
    }

    /// Update position to match the pane's frame in screen coordinates
    func updateFrame(_ screenFrame: NSRect) {
        childWindow?.setFrame(screenFrame, display: true)
    }

    /// Give keyboard focus to this terminal
    func focus() {
        guard let child = childWindow else { return }
        // Make the child window key so it receives keyboard events
        child.makeKey()
        child.makeFirstResponder(terminalView)
    }

    func teardown() {
        if let child = childWindow {
            parentWindow?.removeChildWindow(child)
            child.orderOut(nil)
            child.close()
        }
        childWindow = nil
        parentWindow = nil
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
