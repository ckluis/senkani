import Foundation

/// Pure facade for resolving `AuthorshipTag` values from explicit
/// operator actions. Phase V.5 round 1 — foundation only.
///
/// The contract that round 1 enforces:
///
/// 1. **No inference.** No method on this namespace inspects an
///    artifact's content (tokens, diff, source) and derives a tag.
///    Inference is a Gebru red-flag rejection — the operator is the
///    sole authority on which tag a row carries.
///
/// 2. **Bypass is explicit.** Callers that already know the tag
///    (CLI flags, fixtures, programmatic backfill) call
///    `tag(forExplicitChoice:)` and the method is a pass-through.
///    The function exists only so that every authorship resolution
///    in the codebase routes through one auditable surface.
///
/// 3. **Unset is a real state.** `tagForUnknownProvenance()` returns
///    `.unset` — never `.humanAuthored` or any of the other states.
///    The save path checks `tag.isExplicit` and prompts the operator
///    when false (round 2 / V.5b).
///
/// This file is deliberately thin. UI prompts (V.5b), CLI backfill
/// (V.5c), and pane badges (V.5d) all depend on this facade — they
/// don't implement their own authorship logic.
public enum AuthorshipTracker {

    /// Pass-through: the caller already chose. Returned verbatim so
    /// the call site is auditable (`grep -n "AuthorshipTracker"`
    /// finds every place a tag is resolved).
    public static func tag(forExplicitChoice choice: AuthorshipTag) -> AuthorshipTag {
        choice
    }

    /// Returned when an artifact is being written but the operator
    /// has not yet chosen a tag. Always `.unset` — never anything
    /// else. Round 2 (V.5b) reads this and surfaces the prompt;
    /// round 1 lets the row land with `.unset` and trusts the
    /// downstream UI to resolve it.
    public static func tagForUnknownProvenance() -> AuthorshipTag {
        .unset
    }

    /// Decode a tag from an on-disk string (SQLite TEXT, JSON, etc).
    /// `nil` input means "the column held NULL" — this is the
    /// legacy state, distinct from `.unset` which is an explicit
    /// in-band value. Returns `.unset` for NULL so callers don't
    /// have to special-case the legacy path; callers that NEED the
    /// distinction should test the column for NULL before decoding.
    ///
    /// Returns `nil` only when a non-NULL string fails to decode —
    /// callers should treat that as a corrupt-row signal.
    public static func decode(_ raw: String?) -> AuthorshipTag? {
        guard let raw, !raw.isEmpty else { return .unset }
        return AuthorshipTag(rawValue: raw)
    }

    /// Encode a tag for on-disk storage. Inverse of `decode`.
    /// `.unset` round-trips as `"unset"` — callers that want to
    /// represent legacy "never-written" must pass `nil` to the
    /// underlying SQL bind helper, not call this method.
    public static func encode(_ tag: AuthorshipTag) -> String {
        tag.rawValue
    }
}
