import SwiftUI
import AppKit
import SwiftTerm

/// SwiftUI placeholder that creates a terminal portal and positions it
/// to overlay this view's frame.
///
/// The actual LocalProcessTerminalView lives on the window's contentView
/// (outside SwiftUI), not inside the SwiftUI view hierarchy. This view
/// is just a transparent spacer that tracks geometry and tells the portal
/// where to position the real terminal.
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
        // This is just a geometry tracker — the real terminal is on
        // the window's contentView, positioned by the portal
        GeometryReader { geo in
            Color.clear
                .onAppear {
                    createPortal()
                }
                .onDisappear {
                    TerminalPortalManager.shared.removePortal(id: paneId)
                }
                .onChange(of: isActive) { _, active in
                    if active {
                        TerminalPortalManager.shared.portal(for: paneId)?.focus()
                    }
                }
                .background(
                    PortalFrameTracker(paneId: paneId, isActive: isActive, onActivate: onActivate)
                )
        }
        .background(Color.black) // Match terminal background
    }

    private func createPortal() {
        let _ = TerminalPortalManager.shared.createPortal(
            id: paneId,
            shellPath: shellPath,
            environment: environment,
            workingDirectory: workingDirectory,
            onProcessExited: onProcessExited
        )
    }
}

// MARK: - Frame Tracker

/// NSViewRepresentable that tracks its frame in window coordinates
/// and updates the terminal portal's position.
///
/// This is a zero-size invisible NSView whose only job is to report
/// its position in the window so the portal terminal can be placed there.
private struct PortalFrameTracker: NSViewRepresentable {
    let paneId: UUID
    let isActive: Bool
    let onActivate: (() -> Void)?

    func makeNSView(context: Context) -> FrameTrackingView {
        let view = FrameTrackingView()
        view.paneId = paneId
        view.onActivate = onActivate
        return view
    }

    func updateNSView(_ nsView: FrameTrackingView, context: Context) {
        nsView.paneId = paneId
        nsView.isActivePane = isActive
        nsView.onActivate = onActivate
        // Trigger a frame update
        nsView.needsLayout = true
    }
}

/// Invisible NSView that tracks its position in the window and
/// positions the terminal portal to match.
class FrameTrackingView: NSView {
    var paneId: UUID?
    var isActivePane = false
    var onActivate: (() -> Void)?
    private var lastFrame: NSRect = .zero

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePortalFrame()
        attachPortalToWindow()
    }

    override func layout() {
        super.layout()
        updatePortalFrame()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        updatePortalFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePortalFrame()
    }

    private func attachPortalToWindow() {
        guard let paneId, let window else { return }
        TerminalPortalManager.shared.portal(for: paneId)?.attach(to: window)

        // Focus after attaching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.isActivePane else { return }
            TerminalPortalManager.shared.portal(for: paneId)?.focus()
        }
    }

    private func updatePortalFrame() {
        guard let paneId, let window, let superview else { return }

        // Convert this view's bounds to window coordinates
        let frameInWindow = convert(bounds, to: nil)

        // Convert to the contentView's coordinate system (flipped)
        guard let contentView = window.contentView else { return }
        let frameInContent = contentView.convert(frameInWindow, from: nil)

        // Only update if frame actually changed
        if frameInContent != lastFrame {
            lastFrame = frameInContent
            TerminalPortalManager.shared.portal(for: paneId)?.updateFrame(frameInContent)
        }
    }

    // Detect clicks on our area to activate the pane
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        // Forward to the terminal for handling
        if let paneId {
            TerminalPortalManager.shared.portal(for: paneId)?.focus()
        }
        super.mouseDown(with: event)
    }
}
