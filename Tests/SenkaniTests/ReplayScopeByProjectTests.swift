import Testing
import Foundation
@testable import Core

/// Regression coverage for `senkani replay run --session ID` scoping.
/// `ReplayCommand.sessionProjectRoot(...)` previously returned nil for
/// every session, which made `agentTraceRowsInWindow(project: nil, ...)`
/// pull every project's rows since `since`. The fix surfaces
/// `sessions.project_root` on `SessionSummaryRow` so the CLI helper can
/// scope the trace window to the session's actual project.
@Suite("Replay — scope by project_root")
struct ReplayScopeByProjectTests {

    private func makeTempDB() -> (SessionDatabase, String) {
        let path = "/tmp/senkani-replay-scope-\(UUID().uuidString).sqlite"
        return (SessionDatabase(path: path), path)
    }

    /// `loadSessions` must surface `project_root` on every row. The CLI
    /// replay helper joins the session id back to a project root via this
    /// field; if the SELECT drops the column, the helper silently regresses
    /// to "all-project" scope.
    @Test func loadSessionsSurfacesProjectRoot() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let projectA = "/tmp/proj-a-\(UUID().uuidString)"
        let projectB = "/tmp/proj-b-\(UUID().uuidString)"
        let sessionA = db.createSession(projectRoot: projectA)
        let sessionB = db.createSession(projectRoot: projectB)
        let sessionNil = db.createSession(projectRoot: nil)

        let rows = db.loadSessions(limit: 100)
        let rowA = rows.first { $0.id == sessionA }
        let rowB = rows.first { $0.id == sessionB }
        let rowNil = rows.first { $0.id == sessionNil }

        #expect(rowA?.projectRoot == SessionDatabase.normalizePath(projectA))
        #expect(rowB?.projectRoot == SessionDatabase.normalizePath(projectB))
        #expect(rowNil?.projectRoot == nil)
    }

    /// End-to-end shape: with two sessions in two projects, replaying
    /// against session A's project root must yield only A's trace rows.
    /// This is the regression the original CLI helper failed — it returned
    /// nil project, so `agentTraceRowsInWindow` pulled both projects.
    @Test func replayWindowScopesToSessionProjectRoot() {
        let (db, path) = makeTempDB()
        defer { TempSessionDatabase.close(db, path: path) }

        let projectA = SessionDatabase.normalizePath("/tmp/proj-a-\(UUID().uuidString)")!
        let projectB = SessionDatabase.normalizePath("/tmp/proj-b-\(UUID().uuidString)")!

        let sessionA = db.createSession(projectRoot: projectA)
        _ = db.createSession(projectRoot: projectB)

        let baseTime = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            db.recordAgentTraceEvent(AgentTraceEvent(
                idempotencyKey: "a-\(i)",
                project: projectA,
                feature: "read",
                result: "success",
                startedAt: baseTime.addingTimeInterval(Double(i)),
                completedAt: baseTime.addingTimeInterval(Double(i) + 0.1),
                tokensIn: 100,
                tokensOut: 500
            ))
        }
        for i in 0..<5 {
            db.recordAgentTraceEvent(AgentTraceEvent(
                idempotencyKey: "b-\(i)",
                project: projectB,
                feature: "read",
                result: "success",
                startedAt: baseTime.addingTimeInterval(Double(i)),
                completedAt: baseTime.addingTimeInterval(Double(i) + 0.1),
                tokensIn: 100,
                tokensOut: 500
            ))
        }

        // Look up session A's project root the way ReplayCommand does.
        let scopedProject = db.loadSessions(limit: 500)
            .first(where: { $0.id == sessionA })?.projectRoot
        #expect(scopedProject == projectA)

        // Filter the replay window the way ReplayCommand does.
        let scopedRows = db.agentTraceRowsInWindow(project: scopedProject, since: baseTime)
        #expect(scopedRows.count == 3, "scoped window must contain only project A's 3 rows")
        #expect(scopedRows.allSatisfy { $0.project == projectA })

        // Sanity: the unscoped window (the buggy old behavior) sees both projects.
        let unscoped = db.agentTraceRowsInWindow(project: nil, since: baseTime)
        #expect(unscoped.count == 8, "unscoped window pulls all 8 rows — the bug we are guarding against")
    }
}
