import Foundation

/// V.10a — HTML Preview render mode. `original` renders content as
/// authored; `designSystem` is reserved for V.10b pattern application.
/// Both modes resolve to the same path in V.10a — the toggle is a
/// surface-only proof that V.10b can wire pattern injection without
/// touching the surface again.
public enum HTMLPreviewMode: String, CaseIterable, Equatable, Sendable, Codable {
    case original
    case designSystem
}

/// Resolves the file path the WebView renders for a given preview
/// mode. V.10a is an identity map (both modes return the same input
/// path); V.10b will branch on `mode` to point `.designSystem` at a
/// styled-output staging file. The static surface keeps the rule
/// unit-testable from Core without instantiating the SwiftUI view.
public enum HTMLPreviewModeResolver {

    /// Shared probe exposing how many times `resolve(for:mode:)` was
    /// invoked per mode. Tests use this to assert the resolution
    /// path runs once per selection change without mutating the file
    /// argument.
    public static let invocationCounter = HTMLPreviewRenderCounter()

    /// Resolve the file path passed to the WebView for `mode`.
    public static func resolve(for filePath: String, mode: HTMLPreviewMode) -> String {
        invocationCounter.bump(mode: mode)
        // V.10a: identity map. V.10b branches here.
        return filePath
    }
}

/// Lightweight counter for the V.10a A/B toggle resolution probe.
/// Class with an internal lock keeps the call site synchronous so
/// SwiftUI body re-evaluation is not blocked.
public final class HTMLPreviewRenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [HTMLPreviewMode: Int] = [:]

    public init() {}

    public func bump(mode: HTMLPreviewMode) {
        lock.lock(); defer { lock.unlock() }
        counts[mode, default: 0] += 1
    }

    public func count(for mode: HTMLPreviewMode) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[mode] ?? 0
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        counts.removeAll()
    }
}
