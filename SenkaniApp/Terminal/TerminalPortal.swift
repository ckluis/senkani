// Terminal portal approach abandoned — terminals are now embedded directly
// via NSViewRepresentable in TerminalViewRepresentable.swift.
//
// The key fix: startProcess is deferred to viewDidMoveToWindow(), not called
// in makeNSView(). This ensures the terminal has a real window and frame
// before the PTY is initialized.

import Foundation

// Stub kept for compilation compatibility
@MainActor
class TerminalPortalManager {
    nonisolated(unsafe) static let shared = TerminalPortalManager()
    func removePortal(id: UUID) {}
}
