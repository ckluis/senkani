import SwiftUI
import Foundation

/// U.2b-2 GUI child a-1 — refusal-banner model + overlay for the visible
/// browser pane.
///
/// When a `dispatch: .pane` validation run refuses, the pane shows this
/// banner at the top of `BrowserPaneView`. It is deliberately minimal.
///
/// SCHNEIER SIDE-CHANNEL GUARD (structural invariant, greppable):
/// the banner surfaces ONLY the failing axis name and the fixture id — the
/// two operator-actionable identifiers. It NEVER renders the failed
/// assertion's payload, the runner's captured output, the validation plan
/// step list, or page text. A structural test asserts this source file
/// never references those forbidden fields; keep the model to these two
/// String fields so the guard stays trivially true.
struct RefusalBanner: Equatable {
    /// The axis whose assertion failed (e.g. "security", "design"). Safe
    /// to display — it names WHICH check, not WHAT the check saw.
    let failingAxis: String
    /// The fixture id the refusal is scoped to. An opaque identifier the
    /// operator can look up out-of-band — carries no page content.
    let fixtureId: String

    /// The Schneier-safe advisory line "Open advisory" writes to dispatch
    /// stdout. Built from the two safe identifiers ONLY.
    var advisoryLine: String {
        "advisory: axis=\(failingAxis) fixture=\(fixtureId)"
    }

    /// Print the advisory to dispatch stdout. The "Open advisory"
    /// affordance calls this. Writes only `advisoryLine` — the two safe
    /// identifiers — so no side-channel leaks through the stdout surface.
    func printAdvisory() {
        FileHandle.standardOutput.write(Data((advisoryLine + "\n").utf8))
    }
}

/// Top-of-pane refusal overlay. Shows `failing_axis` + `fixture_id`, a
/// single `✕` dismiss, and an "Open advisory" affordance that prints the
/// advisory to dispatch stdout.
struct RefusalBannerView: View {
    let banner: RefusalBanner
    /// Operator dismissed the banner (the `✕`) — the pane unlocks.
    let onDismiss: () -> Void
    /// Operator asked to open the advisory — prints it to dispatch stdout.
    let onOpenAdvisory: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 1) {
                Text("Validation refused")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                // The ONLY two fields the banner shows — Schneier guard.
                Text("axis: \(banner.failingAxis)   ·   fixture: \(banner.fixtureId)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 8)

            Button(action: onOpenAdvisory) {
                Text("Open advisory")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Print the refusal advisory (axis + fixture only) to dispatch stdout")

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Dismiss — unlocks the pane")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.88))
        .cornerRadius(6)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .shadow(radius: 3)
    }
}
