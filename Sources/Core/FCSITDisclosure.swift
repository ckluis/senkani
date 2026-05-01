import Foundation

/// Canonical info for the five compact per-pane toggles ("F", "C",
/// "S", "I", "T") that live in the pane header.
///
/// The pane header trades clarity for density: a first-time user sees
/// five single uppercase letters with no labels and has to guess that
/// "F" is Filter and that tapping it does anything at all. This type
/// is the single source of truth for the letter → name → effect
/// mapping the SwiftUI surface layer reads to:
///
///   1. Render an `accessibilityLabel` (so VoiceOver names the
///      control instead of reading the letter glyph).
///   2. Render the first-use disclosure popover that names every
///      letter in one place.
///   3. Stay in sync with `FeatureDetailDrawer` (in
///      `SavingsCardView.swift`) and `PaneSettingsPanel`'s
///      Optimization section without duplicating five copy strings
///      across three views.
///
/// Strings here are intentionally short — the long-form description
/// + benefits live in `FeatureInfo.lookup(...)` (the SwiftUI view
/// layer's struct) which can pull in marketing copy. This decider
/// stays pure-Foundation so SenkaniTests can pin the contract
/// without linking SwiftUI.
public enum FCSITDisclosure {

    /// One toggle's metadata. `letter` is what the pane header
    /// renders; `name` is the literal feature name; `effect` is the
    /// one-sentence outcome the toggle delivers — phrased so a user
    /// who has never seen Senkani before can decide whether they
    /// want it on. `firstUseExplanation` is the line shown in the
    /// first-use disclosure popover.
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let letter: String
        public let name: String
        public let effect: String
        public let firstUseExplanation: String
        public let defaultOn: Bool

        public init(
            key: String,
            letter: String,
            name: String,
            effect: String,
            firstUseExplanation: String,
            defaultOn: Bool
        ) {
            self.key = key
            self.letter = letter
            self.name = name
            self.effect = effect
            self.firstUseExplanation = firstUseExplanation
            self.defaultOn = defaultOn
        }
    }

    /// Ordered list of toggles — order matches the pane-header render
    /// order ("F C S I T"). Tests pin this order so a refactor that
    /// silently reorders the toggles doesn't ship.
    public static let all: [Entry] = [
        Entry(
            key: "filter",
            letter: "F",
            name: "Filter",
            effect: "Strips ANSI codes and compresses tool output before the agent reads it.",
            firstUseExplanation: "F — Filter: compresses tool output (60–90% fewer tokens).",
            defaultOn: true
        ),
        Entry(
            key: "cache",
            letter: "C",
            name: "Cache",
            effect: "Skips re-reading files the agent already read this session.",
            firstUseExplanation: "C — Cache: returns unchanged files instantly (50–99% fewer tokens).",
            defaultOn: true
        ),
        Entry(
            key: "secrets",
            letter: "S",
            name: "Secrets",
            effect: "Redacts API keys and tokens from tool output before the agent sees them.",
            firstUseExplanation: "S — Secrets: redacts API keys and tokens before the model sees them.",
            defaultOn: true
        ),
        Entry(
            key: "indexer",
            letter: "I",
            name: "Indexer",
            effect: "Lets the agent navigate by symbol name instead of reading whole files.",
            firstUseExplanation: "I — Indexer: symbol-level code search (~95% fewer tokens vs full reads).",
            defaultOn: true
        ),
        Entry(
            key: "terse",
            letter: "T",
            name: "Terse",
            effect: "Tells the agent to minimize output verbosity.",
            firstUseExplanation: "T — Terse: trims agent output (50–75% fewer output tokens). Off by default.",
            defaultOn: false
        ),
    ]

    /// Lookup by toggle key — returns nil for unknown keys. Mirrors
    /// the FeatureFlags fields ("filter"/"cache"/"secrets"/"indexer"/
    /// "terse") used elsewhere in the app.
    public static func entry(forKey key: String) -> Entry? {
        all.first { $0.key == key }
    }

    /// Accessibility label string for the compact letter button.
    /// Combines the literal name and current state so VoiceOver
    /// announces "Filter, on" instead of "F".
    public static func accessibilityLabel(forKey key: String, isOn: Bool) -> String {
        guard let e = entry(forKey: key) else { return key }
        return "\(e.name), \(isOn ? "on" : "off")"
    }

    /// Accessibility hint — what activating the control does.
    public static func accessibilityHint(forKey key: String) -> String {
        guard let e = entry(forKey: key) else { return "" }
        return e.effect
    }

    /// Title for the first-use disclosure popover.
    public static let firstUseTitle = "Five per-pane optimizers"

    /// Body lines for the first-use disclosure popover, in order.
    public static var firstUseBody: [String] {
        all.map(\.firstUseExplanation)
    }

    /// Footer hint shown below the body lines.
    public static let firstUseFooter =
        "Tap a letter to toggle it. Double-click for stats and details."

    /// `UserDefaults` key the SwiftUI layer flips after the user
    /// dismisses the first-use disclosure. Centralized here so tests
    /// can pin the spelling and so multiple views agree on it.
    public static let firstUseSeenDefaultsKey =
        "senkani.fcsit.firstUseDisclosureSeen.v1"

    /// Decide whether to show the first-use disclosure to a user
    /// whose `seen` flag has the given value. Pure logic so tests
    /// can pin the rule without instantiating UserDefaults.
    public static func shouldShowFirstUse(seen: Bool) -> Bool {
        !seen
    }
}
