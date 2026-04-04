import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI placeholder for a terminal pane. The actual terminal lives
/// in a child NSWindow (see TerminalPortal.swift), positioned to
/// overlay this view's frame.
struct TerminalViewRepresentable: View {
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

    var body: some View {
        // Black background matches the terminal
        Color.black
            .background(
                PortalFrameTracker(
                    paneId: paneId,
                    shellPath: shellPath,
                    environment: environment,
                    workingDirectory: workingDirectory,
                    isActive: isActive,
                    onProcessExited: onProcessExited,
                    onActivate: onActivate
                )
            )
    }
}

// MARK: - Frame Tracker

/// NSViewRepresentable that tracks its frame in SCREEN coordinates
/// and positions the terminal's child window to match.
private struct PortalFrameTracker: NSViewRepresentable {
    let paneId: UUID
    let shellPath: String
    let environment: [String: String]
    let workingDirectory: String
    let isActive: Bool
    let onProcessExited: ((Int32) -> Void)?
    let onActivate: (() -> Void)?

    func makeNSView(context: Context) -> FrameTrackingView {
        let view = FrameTrackingView()
        view.paneId = paneId
        view.shellPath = shellPath
        view.environment = environment
        view.workingDirectory = workingDirectory
        view.onProcessExited = onProcessExited
        view.onActivate = onActivate
        view.isActivePane = isActive
        return view
    }

    func updateNSView(_ nsView: FrameTrackingView, context: Context) {
        nsView.isActivePane = isActive
        if isActive {
            TerminalPortalManager.shared.portal(for: paneId)?.focus()
        }
        nsView.syncPortalFrame()
    }
}

/// Invisible NSView that creates the terminal portal on window attach
/// and continuously syncs its screen-space frame.
class FrameTrackingView: NSView {
    var paneId: UUID?
    var shellPath: String = "/bin/zsh"
    var environment: [String: String] = [:]
    var workingDirectory: String = NSHomeDirectory()
    var isActivePane = false
    var onProcessExited: ((Int32) -> Void)?
    var onActivate: (() -> Void)?
    private var portalCreated = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        createPortalIfNeeded()
        syncPortalFrame()
    }

    override func layout() {
        super.layout()
        syncPortalFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncPortalFrame()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        // When removed from superview, clean up
        if superview == nil, let paneId {
            TerminalPortalManager.shared.removePortal(id: paneId)
            portalCreated = false
        }
    }

    private func createPortalIfNeeded() {
        guard let paneId, let window, !portalCreated else { return }
        portalCreated = true

        let portal = TerminalPortalManager.shared.createPortal(
            id: paneId,
            shellPath: shellPath,
            environment: environment,
            workingDirectory: workingDirectory,
            onProcessExited: onProcessExited
        )
        portal.attach(to: window)

        // Focus after a delay
        if isActivePane {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                portal.focus()
            }
        }
    }

    func syncPortalFrame() {
        guard let paneId, let window else { return }
        guard let portal = TerminalPortalManager.shared.portal(for: paneId) else { return }

        // Convert bounds to screen coordinates for the child window
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = window.convertToScreen(frameInWindow)

        portal.updateFrame(frameOnScreen)
    }
}
