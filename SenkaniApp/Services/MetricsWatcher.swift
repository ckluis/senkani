import Foundation

// DEPRECATED: MetricsWatcher has been replaced by the DB-driven MetricsRefresher.
// The MCP server now writes to token_events in SessionDatabase, and MetricsRefresher
// polls the DB on a 1-second timer for open terminal panes.
// This file is kept empty to avoid stale Xcode project references.
