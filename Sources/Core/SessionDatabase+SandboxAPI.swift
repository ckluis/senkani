import Foundation

extension SessionDatabase {
    /// Store a large command output and return a retrieve ID.
    public func storeSandboxedResult(sessionId: String, command: String, output: String) -> String {
        sandboxStore.storeSandboxedResult(sessionId: sessionId, command: command, output: output)
    }

    /// Retrieve a sandboxed result by its ID.
    public func retrieveSandboxedResult(resultId: String) -> (command: String, output: String, lineCount: Int, byteCount: Int)? {
        sandboxStore.retrieveSandboxedResult(resultId: resultId)
    }

    /// Delete sandboxed results older than a given interval.
    @discardableResult
    public func pruneSandboxedResults(olderThan interval: TimeInterval = 86400) -> Int {
        sandboxStore.pruneSandboxedResults(olderThan: interval)
    }
}
