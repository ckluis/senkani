import SwiftUI
import Core

/// Phase V.5d — thin SwiftUI host over `AuthorshipBadge.Descriptor`.
///
/// All copy + weight rules live in `Sources/Core/AuthorshipBadge.swift`
/// so unit tests lock the rules without instantiating SwiftUI. This
/// view maps the pure-data `Weight` to a foreground color, opacity,
/// and capsule fill — visual tier only.
///
/// Keep visual weight LOW. The acceptance for V.5d is "metadata, not
/// status" — these badges sit beside primary content like type tags
/// and counts; they must not steal focus.
struct AuthorshipBadgeView: View {

    let descriptor: AuthorshipBadge.Descriptor

    /// Convenience init for callers that already have a tag + surface.
    init(tag: AuthorshipTag?, context: AuthorshipBadge.BadgeContext) {
        self.descriptor = AuthorshipBadge.descriptor(for: tag, context: context)
    }

    init(descriptor: AuthorshipBadge.Descriptor) {
        self.descriptor = descriptor
    }

    var body: some View {
        Text(descriptor.label)
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(foreground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(fill))
            .help(descriptor.tooltip)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text(descriptor.tooltip))
    }

    // MARK: - Visual mapping

    private var foreground: Color {
        switch descriptor.weight {
        case .explicit:
            // The three explicit tags ride the KB accent — the
            // surface that owns the column today. Low weight, but
            // visible.
            return SenkaniTheme.accentKnowledgeBase
        case .unset:
            // Operator owes a decision — slight orange nudge so it
            // catches the eye without screaming.
            return SenkaniTheme.accentDiffViewer.opacity(0.85)
        case .legacy:
            // Pre-V.5 NULL on a tracked surface. Subdued; a backfill
            // run flips it to explicit.
            return SenkaniTheme.textTertiary.opacity(0.7)
        case .untracked:
            // Surface doesn't carry the column. Lowest weight — this
            // is informational, not actionable.
            return SenkaniTheme.textTertiary.opacity(0.55)
        }
    }

    private var fill: Color {
        switch descriptor.weight {
        case .explicit: return SenkaniTheme.accentKnowledgeBase.opacity(0.12)
        case .unset:    return SenkaniTheme.accentDiffViewer.opacity(0.12)
        case .legacy:   return SenkaniTheme.paneShell.opacity(0.6)
        case .untracked: return SenkaniTheme.paneShell.opacity(0.4)
        }
    }

    private var accessibilityLabel: String {
        switch descriptor.weight {
        case .explicit:  return "Authored: \(descriptor.label)"
        case .unset:     return "Authorship not tagged"
        case .legacy:    return "Authorship not tagged (legacy entry)"
        case .untracked: return "Authorship not tracked on this surface"
        }
    }
}
