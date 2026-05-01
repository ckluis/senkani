import SwiftUI
import Core

/// First-use disclosure for the five compact letter toggles in the
/// pane header. Shown the first time the user hovers or taps an
/// FCSIT letter; flips a UserDefaults flag on dismiss so the user
/// never sees it again. Copy lives in `Core.FCSITDisclosure` so
/// SenkaniTests can pin the contract.
struct FCSITFirstUsePopover: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(FCSITDisclosure.firstUseTitle)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                ForEach(FCSITDisclosure.all, id: \.key) { entry in
                    Text(entry.firstUseExplanation)
                        .font(.system(size: 11))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(FCSITDisclosure.firstUseFooter)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Got it") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(FCSITDisclosure.firstUseTitle))
    }
}

#if DEBUG
#Preview {
    FCSITFirstUsePopover(onDismiss: {})
}
#endif
