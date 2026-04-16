import SwiftUI
import UniformTypeIdentifiers

/// Horizontally-scrollable pane canvas with resizable columns.
///
/// Each pane occupies a column whose width the user can drag-resize from
/// its right edge. The canvas scrolls freely — growing a pane does not
/// shrink its neighbors.
struct PaneGridView: View {
    let panes: [PaneModel]
    let activePaneID: UUID?
    var workspace: WorkspaceModel?

    private var paneTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: 0.8, anchor: .trailing))
                .combined(with: .move(edge: .trailing)),
            removal: .opacity
                .combined(with: .scale(scale: 0.8, anchor: .center))
        )
    }

    var body: some View {
        GeometryReader { geo in
            let availableHeight = geo.size.height - SenkaniTheme.columnSpacing * 2

            if panes.isEmpty {
                EmptyView()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: SenkaniTheme.columnSpacing) {
                            ForEach(Array(panes.enumerated()), id: \.element.id) { index, pane in
                                paneColumn(
                                    pane,
                                    isActive: pane.id == activePaneID,
                                    availableHeight: availableHeight,
                                    index: index
                                )
                                .id(pane.id)
                                .transition(paneTransition)
                            }
                        }
                        .padding(SenkaniTheme.columnSpacing)
                    }
                    .scrollIndicators(.visible, axes: .horizontal)
                    .onChange(of: activePaneID) { _, newID in
                        if let newID {
                            withAnimation(SenkaniTheme.paneEntranceAnimation) {
                                proxy.scrollTo(newID, anchor: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .background(SenkaniTheme.appBackground)
    }

    @ViewBuilder
    private func paneColumn(_ pane: PaneModel, isActive: Bool, availableHeight: CGFloat, index: Int) -> some View {
        let height = pane.paneHeight ?? availableHeight

        ZStack(alignment: .trailing) {
            VStack(spacing: 0) {
                PaneContainerView(
                    pane: pane,
                    isActive: isActive,
                    workspace: workspace
                )
                .frame(height: height)

                Spacer(minLength: 0)
            }

            // Right-edge resize handle
            PaneRightEdgeHandle(
                pane: pane,
                isActive: isActive,
                accentColor: SenkaniTheme.accentColor(for: pane.paneType)
            )
        }
        .frame(width: pane.columnWidth, height: availableHeight)
        .clipped()
        .animation(nil, value: pane.columnWidth)
        // Drop target for reordering
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { string, _ in
                guard let uuidString = string as? String,
                      let sourceID = UUID(uuidString: uuidString) else { return }
                DispatchQueue.main.async {
                    workspace?.movePane(id: sourceID, toIndex: index)
                }
            }
            return true
        }
    }
}

// MARK: - Right Edge Resize Handle

/// A right-edge resize handle overlaid on each pane.
/// Dragging changes only this pane's width — neighbors are unaffected.
/// The ScrollView handles overflow naturally.
private struct PaneRightEdgeHandle: View {
    let pane: PaneModel
    let isActive: Bool
    let accentColor: Color

    @State private var isDragging = false
    @State private var startWidth: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        ZStack(alignment: .trailing) {
            // Invisible hit target
            Color.clear
                .frame(width: SenkaniTheme.resizeHandleHitWidth)
                .contentShape(Rectangle())

            // Visible accent bar — shown for active pane, while dragging, or on hover
            if isActive || isDragging || isHovering {
                ZStack {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accentColor.opacity(isDragging ? 0.7 : 0.3))
                        .frame(width: SenkaniTheme.resizeHandleWidth)
                        .padding(.vertical, 32)

                    // Grip dots — 3 stacked circles centered on the bar
                    VStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle()
                                .fill(accentColor.opacity(isDragging ? 0.9 : 0.5))
                                .frame(width: 3, height: 3)
                        }
                    }
                }
            }
        }
        .frame(width: SenkaniTheme.resizeHandleHitWidth)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if !isDragging {
                        startWidth = pane.columnWidth
                        isDragging = true
                    }
                    let newWidth = max(
                        SenkaniTheme.minColumnWidth,
                        min(SenkaniTheme.maxColumnWidth, startWidth + value.translation.width)
                    )
                    // Disable animations during drag to prevent jank
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        pane.columnWidth = newWidth
                    }
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}
