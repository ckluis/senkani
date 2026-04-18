import Foundation

/// Terminal-font settings for a pane: point size + family name.
///
/// Pure Foundation — no AppKit — so the SenkaniTests target (which does
/// not depend on SenkaniApp) can exercise the clamp, fallback, and
/// change-detection logic. AppKit resolution (`NSFont(name:size:)`) stays
/// in the view layer.
public struct PaneFontSettings: Codable, Equatable, Sendable {
    public var fontSize: Double
    public var fontFamily: String

    public init(fontSize: Double = PaneFontSettings.defaultFontSize,
                fontFamily: String = PaneFontSettings.defaultFontFamily) {
        self.fontSize = fontSize
        self.fontFamily = fontFamily
    }

    // MARK: - Defaults & bounds

    /// Default terminal font size in points. Matches the existing
    /// `PaneModel.fontSize` / `TerminalViewRepresentable` default so the
    /// first-run experience is unchanged.
    public static let defaultFontSize: Double = 12.0

    /// Minimum and maximum sliders accept. Superset of the 9–20 range
    /// documented in the backlog acceptance; we retain the broader 8–24
    /// already shipped on the Display slider.
    public static let minFontSize: Double = 8.0
    public static let maxFontSize: Double = 24.0

    /// Default monospace family. `SF Mono` is the system choice on macOS
    /// and always resolvable via `NSFont(name:size:)` on a modern
    /// install; `monospacedSystemFont` is the AppKit fallback when the
    /// name lookup misses.
    public static let defaultFontFamily: String = "SF Mono"

    /// Curated picker list — the families surfaced in Display settings.
    /// Hard-coded (not queried from `NSFontManager`) so tests are
    /// deterministic across machines.
    public static let availableMonospaceFamilies: [String] = [
        "SF Mono",
        "Menlo",
        "Monaco",
        "Courier",
        "Courier New",
        "Andale Mono",
    ]

    // MARK: - Pure helpers

    /// Clamp an arbitrary input size into `[minFontSize, maxFontSize]`.
    public static func clampFontSize(_ raw: Double) -> Double {
        if raw < minFontSize { return minFontSize }
        if raw > maxFontSize { return maxFontSize }
        return raw
    }

    /// Resolve a requested family name against the curated list. Returns
    /// the requested family if it is known, otherwise `defaultFontFamily`.
    /// The view layer still runs an `NSFont(name:size:)` check and falls
    /// back again if even the default name misses — two-layer safety.
    public static func resolveFamily(requested: String) -> String {
        if availableMonospaceFamilies.contains(requested) {
            return requested
        }
        return defaultFontFamily
    }

    /// Whether a re-apply is needed. The 0.5pt threshold matches the
    /// existing `TerminalViewRepresentable.updateNSView` diff check so a
    /// single change (slider step = 1pt) fires exactly one re-apply.
    public static func fontSizeDidChange(from currentSize: Double,
                                         to newSize: Double) -> Bool {
        abs(currentSize - newSize) > 0.5
    }

    /// Whether the family differs. String comparison is exact — callers
    /// are expected to pass resolved (curated) names.
    public static func fontFamilyDidChange(from current: String,
                                           to new: String) -> Bool {
        current != new
    }
}
