import Foundation

/// Phase V.5b — pure resolver for the save-path authorship prompt.
///
/// The contract this file enforces:
///
/// 1. **Predicate is total.** `needsPrompt(priorAuthorship:)` covers
///    every case of `AuthorshipTag?`. `nil` (legacy NULL row) and
///    `.unset` (V.5 round 1 sentinel) both prompt; the three explicit
///    tags don't. Switch is exhaustive — adding a new `AuthorshipTag`
///    case forces a compile error here, which is the intended trip-
///    wire.
///
/// 2. **No inference.** `resolve(choice:)` is a pure pass-through to
///    `AuthorshipTracker.tag(forExplicitChoice:)`. No content
///    inspection, no defaulting, no timeout-based silent resolution.
///    Cavoukian red-flag holds: the operator is the sole authority.
///
/// 3. **Copy lives here.** The Podmajersky-reviewed strings are
///    static constants so any UI host (the SwiftUI sheet today, a
///    future TUI / web surface) renders the same words, and unit
///    tests can lock the voice rules without touching SwiftUI.
///
/// The SwiftUI sheet at `SenkaniApp/Views/AuthorshipPromptSheet.swift`
/// is a thin presentation layer over this enum.
public enum AuthorshipPromptResolver {

    // MARK: - Copy (Podmajersky-reviewed, V.5b)

    /// 1-line, verb-first question. No marketing voice, no jargon.
    public static let questionCopy = "Who wrote this?"

    /// Button labels. Match `AuthorshipTag.displayLabel` for the three
    /// explicit cases — duplicated as static let so tests can lock the
    /// strings without re-deriving them at runtime.
    public static let aiButtonLabel    = "AI"
    public static let humanButtonLabel = "Human"
    public static let mixedButtonLabel = "Mixed"

    /// Tertiary action: defer the decision. Does NOT silently save.
    /// The operator returns to the editor with the row still dirty.
    public static let skipButtonLabel  = "Skip for now"

    // MARK: - Predicate

    /// Whether the save path should surface the prompt before
    /// committing the row.
    ///
    /// `nil` — legacy column, never written through the V.5 path.
    /// `.unset` — V.5 round 1 sentinel that the operator owes a
    /// decision on.
    ///
    /// The three explicit tags pass through silently; the operator
    /// has already chosen and a save that preserves that choice is
    /// not a Gebru-style rewrite.
    public static func needsPrompt(priorAuthorship: AuthorshipTag?) -> Bool {
        switch priorAuthorship {
        case .none, .some(.unset):
            return true
        case .some(.aiAuthored), .some(.humanAuthored), .some(.mixed):
            return false
        }
    }

    /// Pass-through to `AuthorshipTracker.tag(forExplicitChoice:)`.
    /// Wired here so a `grep "AuthorshipPromptResolver.resolve"` finds
    /// every place the prompt path turns a button-press into a tag.
    public static func resolve(choice: AuthorshipTag) -> AuthorshipTag {
        AuthorshipTracker.tag(forExplicitChoice: choice)
    }
}
