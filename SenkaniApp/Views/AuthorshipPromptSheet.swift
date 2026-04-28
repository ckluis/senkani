import SwiftUI
import Core

/// Phase V.5b — SwiftUI prompt surface for the AuthorshipTag.
///
/// Render contract (Podmajersky / Norman / Cavoukian-aligned):
///   - 1-line, verb-first question (no marketing voice, no jargon)
///   - 3 explicit buttons (AI / Human / Mixed), none preselected — no
///     silent default that the operator might miss
///   - Tertiary "Skip for now" returns control to the editor without
///     saving (Cavoukian red flag: never resolve `.unset` silently)
///
/// All copy lives in `AuthorshipPromptResolver` so unit tests can lock
/// the voice rules without instantiating SwiftUI.
struct AuthorshipPromptSheet: View {

    /// Operator picked one of the three tags.
    let onChoice: (AuthorshipTag) -> Void

    /// Operator hit Skip — sheet dismisses, row stays dirty, no save.
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            Text(AuthorshipPromptResolver.questionCopy)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)

            HStack(spacing: 8) {
                choiceButton(label: AuthorshipPromptResolver.aiButtonLabel) {
                    onChoice(AuthorshipPromptResolver.resolve(choice: .aiAuthored))
                }
                choiceButton(label: AuthorshipPromptResolver.humanButtonLabel) {
                    onChoice(AuthorshipPromptResolver.resolve(choice: .humanAuthored))
                }
                choiceButton(label: AuthorshipPromptResolver.mixedButtonLabel) {
                    onChoice(AuthorshipPromptResolver.resolve(choice: .mixed))
                }
            }

            HStack {
                Spacer()
                Button(AuthorshipPromptResolver.skipButtonLabel) { onSkip() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(SenkaniTheme.paneBody)
    }

    private func choiceButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(SenkaniTheme.accentKnowledgeBase))
        }
        .buttonStyle(.plain)
    }
}
