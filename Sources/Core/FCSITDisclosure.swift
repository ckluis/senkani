import Foundation

/// Canonical info for the five compact per-pane toggles ("F", "C",
/// "S", "I", "T") that live in the pane header.
///
/// The pane header trades clarity for density: a first-time user sees
/// five single uppercase letters with no labels and has to guess that
/// "F" is Filter and that clicking it does anything at all. This type
/// is the single source of truth for the letter → name → effect
/// mapping the SwiftUI surface layer reads to:
///
///   1. Render an `accessibilityLabel` (so VoiceOver names the
///      control instead of reading the letter glyph).
///   2. Render the Optimization rows in `PaneSettingsPanel` — the
///      canonical surface a user reaches by clicking any FCSIT
///      letter, where each toggle sits next to its explanation.
///
/// Strings here are intentionally short — the long-form description
/// + per-feature explainer copy lives in
/// `docs/concepts/per-pane-optimizers.html`, linked per-row from the
/// settings panel via `[Learn more →]`. This decider stays
/// pure-Foundation so SenkaniTests can pin the contract without
/// linking SwiftUI.
public enum FCSITDisclosure {

    /// One toggle's metadata. `letter` is what the pane header
    /// renders; `name` is the literal feature name; `effect` is the
    /// one-sentence outcome the toggle delivers — phrased so a user
    /// who has never seen Senkani before can decide whether they
    /// want it on.
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let letter: String
        public let name: String
        public let effect: String
        public let defaultOn: Bool

        public init(
            key: String,
            letter: String,
            name: String,
            effect: String,
            defaultOn: Bool
        ) {
            self.key = key
            self.letter = letter
            self.name = name
            self.effect = effect
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
            defaultOn: true
        ),
        Entry(
            key: "cache",
            letter: "C",
            name: "Cache",
            effect: "Skips re-reading files the agent already read this session.",
            defaultOn: true
        ),
        Entry(
            key: "secrets",
            letter: "S",
            name: "Secrets",
            effect: "Redacts API keys and tokens from tool output before the agent sees them.",
            defaultOn: true
        ),
        Entry(
            key: "indexer",
            letter: "I",
            name: "Indexer",
            effect: "Lets the agent navigate by symbol name instead of reading whole files.",
            defaultOn: true
        ),
        Entry(
            key: "terse",
            letter: "T",
            name: "Terse",
            effect: "Tells the agent to minimize output verbosity.",
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

    /// Retired UserDefaults key that gated the first-use disclosure
    /// popover (`FCSITFirstUsePopover`, removed 2026-05-11 alongside
    /// the chevron / gear / drawer surfaces). The settings panel
    /// reached by clicking any letter is now the canonical
    /// explainer. SenkaniGUI removes this key on launch so a single
    /// upgrade visit clears stale state from disk.
    public static let retiredFirstUseSeenDefaultsKey =
        "senkani.fcsit.firstUseDisclosureSeen.v1"

    /// Documentation URL for a given toggle. Settings panel rows
    /// render this as `[Learn more →]` beneath their subtitle.
    /// Hardcoded to the canonical docs host — matches the existing
    /// convention of cross-linking to `senkani.app/docs/*`.
    public static func learnMoreURL(forKey key: String) -> URL? {
        URL(string: "https://senkani.app/docs/concepts/per-pane-optimizers.html#\(key)")
    }
}
