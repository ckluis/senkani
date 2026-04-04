// This file intentionally left minimal.
// Terminal portal (separate window) approach was abandoned.
// Terminals are now embedded directly via NSViewRepresentable
// in TerminalViewRepresentable.swift using the FocusableTerminalView
// pattern from cmux. The setActivationPolicy(.regular) in main.swift
// was the missing piece that makes this work.

import AppKit
import SwiftTerm

// TerminalPortalManager kept as no-op for compatibility
@MainActor
class TerminalPortalManager {
    nonisolated(unsafe) static let shared = TerminalPortalManager()
    func removePortal(id: UUID) {}
    func portal(for id: UUID) -> AnyObject? { nil }
}
