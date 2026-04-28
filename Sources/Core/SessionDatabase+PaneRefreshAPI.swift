import Foundation

extension SessionDatabase {
    /// Persist a tile's refresh state. The store appends a new row each call;
    /// rehydration reads `MAX(id)` per (project_root, tile_id).
    public func recordPaneRefreshState(
        projectRoot: String, tileId: String, state: PaneRefreshState
    ) {
        paneRefreshStateStore.recordOutcome(
            projectRoot: projectRoot, tileId: tileId, state: state
        )
    }

    /// Latest persisted state for one tile, or nil if never persisted.
    public func paneRefreshState(projectRoot: String, tileId: String) -> PaneRefreshState? {
        paneRefreshStateStore.latestState(projectRoot: projectRoot, tileId: tileId)
    }

    /// Latest-per-tile states for a project. The coordinator calls this once
    /// on app start to rehydrate every tile in one query.
    public func paneRefreshStates(projectRoot: String) -> [String: PaneRefreshState] {
        paneRefreshStateStore.latestStates(projectRoot: projectRoot)
    }
}
