import SwiftUI

/// Horizontally-scrollable pane canvas with resizable columns.
///
/// Each pane occupies a column whose width the user can drag to resize.
/// A thin drag handle sits between adjacent columns. The canvas scrolls
/// freely; the rightmost column extends past the window edge as a scroll
/// affordance.
struct PaneGridView: View {
    let panes: [PaneModel]
    let activePaneID: UUID?
    var workspace: WorkspaceModel?

    var body: some View {
        GeometryReader { geo in
            if panes.isEmpty {
                EmptyView()
            } else if panes.count == 1 {
                PaneContainerView(
                    pane: panes[0],
                    isActive: true,
                    workspace: workspace
                )
                .padding(SenkaniTheme.columnSpacing)
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                            // Pane column
                            PaneContainerView(
                                pane: pane,
                                isActive: pane.id == activePaneID,
                                workspace: workspace
                            )
                            .frame(width: pane.columnWidth)

                            // Drag handle between columns (not after the last)
                            if index < panes.count - 1 {
                                PaneResizeHandle(
                                    leftPane: pane,
                                    rightPane: panes[index + 1]
                                )
                            }
                        }
                    }
                    .padding(.horizontal, SenkaniTheme.columnSpacing)
                    .padding(.vertical, SenkaniTheme.columnSpacing)
                }
                .scrollIndicators(.visible, axes: .horizontal)
                .onTapGesture {
                    workspace?.activePaneID = nil
                }
            }
        }
        .background(SenkaniTheme.appBackground)
    }
}

// MARK: - Resize Handle

/// A thin vertical drag handle between two pane columns.
/// Dragging left shrinks the left pane and grows the right; dragging
/// right does the opposite. Both panes respect `minColumnWidth`.
private struct PaneResizeHandle: View {
    let leftPane: PaneModel
    let rightPane: PaneModel

    @State private var isDragging = false

    private let handleWidth: CGFloat = SenkaniTheme.columnSpacing
    private let hitTargetWidth: CGFloat = 12  // wider invisible hit area

    var body: some View {
        ZStack {
            // Visible line
            Rectangle()
                .fill(isDragging ? SenkaniTheme.focusBorder : SenkaniTheme.inactiveBorder)
                .frame(width: 1)
                .animation(SenkaniTheme.focusAnimation, value: isDragging)

            // Invisible wider hit target
            Color.clear
                .frame(width: hitTargetWidth)
                .contentShape(Rectangle())
        }
        .frame(width: handleWidth)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    let delta = value.translation.width

                    let newLeftWidth = leftPane.columnWidth + delta
                    let newRightWidth = rightPane.columnWidth - delta

                    // Enforce minimum widths
                    if newLeftWidth >= SenkaniTheme.minColumnWidth &&
                       newRightWidth >= SenkaniTheme.minColumnWidth {
                        leftPane.columnWidth = newLeftWidth
                        rightPane.columnWidth = newRightWidth
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}
