import SwiftUI

/// Horizontally-scrollable pane canvas.
///
/// Each pane occupies a fixed-width column. The canvas scrolls freely.
/// The rightmost column is intentionally allowed to extend past the window
/// edge, acting as a natural scroll affordance.
struct PaneGridView: View {
    let panes: [PaneModel]
    let activePaneID: UUID?
    var workspace: WorkspaceModel?

    var body: some View {
        GeometryReader { geo in
            if panes.isEmpty {
                EmptyView()
            } else if panes.count == 1 {
                // Single pane: fill the entire canvas, no scroll.
                PaneContainerView(
                    pane: panes[0],
                    isActive: true,
                    workspace: workspace
                )
                .padding(SenkaniTheme.columnSpacing)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: SenkaniTheme.columnSpacing) {
                        ForEach(panes) { pane in
                            PaneContainerView(
                                pane: pane,
                                isActive: pane.id == activePaneID,
                                workspace: workspace
                            )
                            .frame(width: columnWidth(for: geo.size))
                        }
                    }
                    .padding(.horizontal, SenkaniTheme.columnSpacing)
                    .padding(.vertical, SenkaniTheme.columnSpacing)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .onTapGesture {
                    // Tap canvas background to clear focus
                    workspace?.activePaneID = nil
                }
            }
        }
        .background(SenkaniTheme.appBackground)
    }

    /// Calculate column width.
    /// With 2 panes, split evenly (minus spacing/padding).
    /// With 3+, use the default fixed width so overflow triggers scroll.
    private func columnWidth(for size: CGSize) -> CGFloat {
        let totalPadding = SenkaniTheme.columnSpacing * 2 // left + right padding
        let totalSpacing = SenkaniTheme.columnSpacing * CGFloat(panes.count - 1)
        let availableWidth = size.width - totalPadding - totalSpacing

        if panes.count == 2 {
            let perPane = availableWidth / 2
            return max(SenkaniTheme.minColumnWidth, perPane)
        }

        // For 3+ panes, use fixed width. Let it overflow for scroll affordance.
        return SenkaniTheme.defaultColumnWidth
    }
}
