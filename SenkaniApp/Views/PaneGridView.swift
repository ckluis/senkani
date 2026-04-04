import SwiftUI

/// Auto-tiling pane grid. Flock-style: 1=full, 2=split, 3=2+1, 4=grid.
struct PaneGridView: View {
    let panes: [PaneModel]
    let activePaneID: UUID?
    var workspace: WorkspaceModel?

    var body: some View {
        GeometryReader { geo in
            switch panes.count {
            case 0:
                EmptyView()
            case 1:
                paneView(panes[0])
            case 2:
                HSplitView {
                    paneView(panes[0])
                    paneView(panes[1])
                }
            case 3:
                HSplitView {
                    paneView(panes[0])
                    VSplitView {
                        paneView(panes[1])
                        paneView(panes[2])
                    }
                }
            default:
                // 4+ panes: 2-column grid
                let leftPanes = Array(panes.prefix(panes.count / 2 + panes.count % 2))
                let rightPanes = Array(panes.suffix(panes.count / 2))
                HSplitView {
                    VSplitView {
                        ForEach(leftPanes) { pane in
                            paneView(pane)
                        }
                    }
                    VSplitView {
                        ForEach(rightPanes) { pane in
                            paneView(pane)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func paneView(_ pane: PaneModel) -> some View {
        PaneContainerView(pane: pane, isActive: pane.id == activePaneID, workspace: workspace)
    }
}
