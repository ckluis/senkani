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

    private let shellPath: String
    private let env: [String]
    private var processStarted = false

    init(id: UUID,
         shellPath: String,
         environment: [String: String],
         workingDirectory: String,
         onProcessExited: ((Int32) -> Void)?) {

        self.id = id
        self.delegate = TerminalDelegate(onProcessExited: onProcessExited)
        self.shellPath = shellPath.isEmpty ? "/bin/zsh" : shellPath

        // Build env pairs now, start process later (after window attach)
        var envDict = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            envDict[key] = value
        }
        envDict["TERM"] = "xterm-256color"
        self.env = envDict.map { "\($0.key)=\($0.value)" }

        let tv = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        tv.autoresizingMask = [.width, .height]
        tv.nativeBackgroundColor = .black
        tv.nativeForegroundColor = .white
        tv.processDelegate = delegate
        self.terminalView = tv
        // DO NOT start process here — must be in a window first
    }

    /// Attach as a child window of the parent.
    ///
    /// Uses a TITLED window with hidden title bar — matching the pure AppKit
    /// test that ACTUALLY WORKED. Borderless windows and child windows both
    /// failed to reliably receive keyboard events.
    func attach(to parent: NSWindow) {
        guard childWindow == nil else { return }
        self.parentWindow = parent

        // TITLED window (like the working test), but with hidden title bar
        // so it looks borderless. This gives us standard key window behavior.
        let child = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        child.titlebarAppearsTransparent = true
        child.titleVisibility = .hidden
        child.isMovableByWindowBackground = false
        child.backgroundColor = .black
        child.hasShadow = false
        child.isReleasedWhenClosed = false
        // Hide the standard window buttons (traffic lights)
        child.standardWindowButton(.closeButton)?.isHidden = true
        child.standardWindowButton(.miniaturizeButton)?.isHidden = true
        child.standardWindowButton(.zoomButton)?.isHidden = true

        // Terminal as subview of contentView (like the working test)
        let container = child.contentView!
        terminalView.frame = container.bounds
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)

        // NOT a child window — standalone, positioned over the pane
        // Child windows can't reliably become key on macOS.
        child.orderFront(nil)
        self.childWindow = child

        // Start shell now that terminal is in a real window
        startProcessIfNeeded()

        // Activate and focus
        child.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        child.makeFirstResponder(terminalView)
    }

    private func startProcessIfNeeded() {
        guard !processStarted else { return }
        processStarted = true

        terminalView.startProcess(
            executable: shellPath,
            args: [],
            environment: env,
            execName: "-" + (shellPath as NSString).lastPathComponent
        )
    }

    /// Update position to match the pane's frame in screen coordinates
    func updateFrame(_ screenFrame: NSRect) {
        guard let child = childWindow else { return }
        // Account for title bar height (even though it's transparent, it takes space)
        let titleBarHeight = child.frame.height - child.contentLayoutRect.height
        var adjusted = screenFrame
        adjusted.size.height += titleBarHeight
        child.setFrame(adjusted, display: true)
    }

    /// Give keyboard focus to this terminal
    func focus() {
        guard let child = childWindow else { return }
        child.makeKeyAndOrderFront(nil)
        child.makeFirstResponder(terminalView)
    }

    func teardown() {
        if let child = childWindow {
            child.orderOut(nil)
            child.close()
        }
        childWindow = nil
        parentWindow = nil
    }
}

// MARK: - KeyableWindow

/// Borderless NSWindow subclass that CAN become key.
/// By default, borderless windows return false for canBecomeKey,
/// which prevents them from receiving keyboard events. This is THE
/// reason the terminal couldn't accept input — the child window
/// silently refused to become key, so keyDown events went to the
/// parent (SwiftUI) window which beeped.
private class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false } // stay as child, don't steal main
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
