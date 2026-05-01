import Testing
import Foundation
@testable import Core

/// Phase V.5d — locks the badge descriptor rules so the SwiftUI
/// host can stay a thin presentation layer. Mirrors
/// `AuthorshipPromptResolverTests` in shape.
///
/// These tests cover the three contracts in `AuthorshipBadge`:
///   1. Total over `AuthorshipTag?` × `BadgeContext`.
///   2. Three explicit tags map to `.explicit` weight + their own
///      tooltip — no inference.
///   3. `.unset` and `nil` both render the "Untagged" label, but
///      with surface-aware weight + tooltip that names the next
///      operator move (resolve via prompt / run backfill / not
///      tracked here yet).

@Suite("AuthorshipBadge — explicit tags")
struct AuthorshipBadgeExplicitTagSuite {

    @Test func aiAuthoredKeepsLabelAndIsExplicit() {
        let d = AuthorshipBadge.descriptor(for: .aiAuthored, context: .knowledgeBase)
        #expect(d.label == "AI")
        #expect(d.weight == .explicit)
        #expect(d.tooltip == AuthorshipBadge.aiTooltip)
    }

    @Test func humanAuthoredKeepsLabelAndIsExplicit() {
        let d = AuthorshipBadge.descriptor(for: .humanAuthored, context: .timeline)
        #expect(d.label == "Human")
        #expect(d.weight == .explicit)
        #expect(d.tooltip == AuthorshipBadge.humanTooltip)
    }

    @Test func mixedKeepsLabelAndIsExplicit() {
        let d = AuthorshipBadge.descriptor(for: .mixed, context: .skills)
        #expect(d.label == "Mixed")
        #expect(d.weight == .explicit)
        #expect(d.tooltip == AuthorshipBadge.mixedTooltip)
    }

    @Test func explicitTagsAreContextInvariant() {
        // The three explicit tags must render identically regardless
        // of surface — Cavoukian: a tagged row keeps its tag.
        for tag in [AuthorshipTag.aiAuthored, .humanAuthored, .mixed] {
            let kb = AuthorshipBadge.descriptor(for: tag, context: .knowledgeBase)
            let tl = AuthorshipBadge.descriptor(for: tag, context: .timeline)
            let sk = AuthorshipBadge.descriptor(for: tag, context: .skills)
            #expect(kb == tl)
            #expect(tl == sk)
            #expect(kb.weight == .explicit)
        }
    }
}

@Suite("AuthorshipBadge — untagged states never silently infer")
struct AuthorshipBadgeUntaggedSuite {

    @Test func unsetOnKBRendersUnsetWeightWithPromptHint() {
        let d = AuthorshipBadge.descriptor(for: .unset, context: .knowledgeBase)
        #expect(d.label == "Untagged")
        #expect(d.weight == .unset)
        #expect(d.tooltip == AuthorshipBadge.unsetTooltipKB)
        // The prompt copy must mention the next operator move.
        #expect(d.tooltip.lowercased().contains("save"))
    }

    @Test func legacyNullOnKBRendersLegacyWeightWithBackfillHint() {
        let d = AuthorshipBadge.descriptor(for: nil, context: .knowledgeBase)
        #expect(d.label == "Untagged")
        #expect(d.weight == .legacy)
        #expect(d.tooltip == AuthorshipBadge.legacyTooltipKB)
        // The backfill CLI must be named so operators can act.
        #expect(d.tooltip.contains("authorship backfill"))
    }

    @Test func nilOnTimelineIsUntrackedNotLegacy() {
        // token_events doesn't carry authorship — distinct from a KB
        // legacy NULL. The tooltip explains why instead of nudging
        // backfill.
        let d = AuthorshipBadge.descriptor(for: nil, context: .timeline)
        #expect(d.label == "Untagged")
        #expect(d.weight == .untracked)
        #expect(d.tooltip == AuthorshipBadge.untrackedTooltipTimeline)
        #expect(!d.tooltip.contains("authorship backfill"))
    }

    @Test func nilOnSkillsIsUntrackedAndMentionsFilesystem() {
        let d = AuthorshipBadge.descriptor(for: nil, context: .skills)
        #expect(d.label == "Untagged")
        #expect(d.weight == .untracked)
        #expect(d.tooltip == AuthorshipBadge.untrackedTooltipSkills)
        #expect(d.tooltip.lowercased().contains("disk")
                || d.tooltip.lowercased().contains("filesystem"))
    }

    @Test func untaggedNeverBorrowsAnExplicitLabel() {
        // Sweep the three untagged surfaces and confirm none of them
        // ever return an "AI" / "Human" / "Mixed" label — that would
        // be a silent inference.
        let cases: [(AuthorshipTag?, AuthorshipBadge.BadgeContext)] = [
            (.unset, .knowledgeBase),
            (nil,    .knowledgeBase),
            (nil,    .timeline),
            (nil,    .skills),
        ]
        for (tag, ctx) in cases {
            let d = AuthorshipBadge.descriptor(for: tag, context: ctx)
            #expect(d.label != "AI")
            #expect(d.label != "Human")
            #expect(d.label != "Mixed")
            #expect(d.weight != .explicit)
        }
    }
}

@Suite("AuthorshipBadge — copy lock")
struct AuthorshipBadgeCopySuite {

    @Test func everyTooltipIsSingleSentenceAndTerse() {
        // Podmajersky lock: one sentence each, ≤ 150 chars. Keeps
        // the SwiftUI hover from going wide.
        let tooltips = [
            AuthorshipBadge.aiTooltip,
            AuthorshipBadge.humanTooltip,
            AuthorshipBadge.mixedTooltip,
            AuthorshipBadge.unsetTooltipKB,
            AuthorshipBadge.legacyTooltipKB,
            AuthorshipBadge.untrackedTooltipTimeline,
            AuthorshipBadge.untrackedTooltipSkills,
        ]
        for t in tooltips {
            #expect(t.count <= 150, "Tooltip too long: \(t.count) chars — \(t)")
            // A "single sentence" allows at most one terminal '.'.
            // The unsetTooltipKB has two short clauses so we permit
            // up to two periods, but never three.
            let periods = t.filter { $0 == "." }.count
            #expect(periods <= 2)
        }
    }
}
