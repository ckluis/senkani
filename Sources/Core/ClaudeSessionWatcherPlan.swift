import Foundation

/// Pure planner for `ClaudeSessionWatcher.checkForNewSession`'s rotation
/// path. Lives in `Core` so the burst-rotation logic is unit-testable from
/// `Tests/SenkaniTests` without pulling the SenkaniApp executable target
/// into test deps.
///
/// Originating finding:
/// `claude-session-watcher-stress-harness-burst-rotation-double-emit-and-partial-drop-2026-05-15`.
/// Under burst (200 probes × 10 lines/probe in ~10s) the prior implementation
/// returned only the most-recent file from the dir scan and skipped any
/// intermediates — causing 5% of probe sessions to be dropped silently
/// (the dirSource-collapse path: multiple files arrive between two
/// `checkForNewSession` runs on `stateQueue`, only the latest "wins"
/// attribution, intermediates are never tailed). The 95% double-emit was a
/// separate bug in the dispatch-source event-handler closure capture; this
/// planner closes the silent-drop half.
public enum ClaudeSessionWatcherPlan {

    public struct DrainPlan: Sendable, Equatable {
        /// Files to call `ClaudeSessionTail.tail(path:)` on before
        /// (re)attaching the watcher. Cursor-idempotent so re-tailing a
        /// fully-read file is cheap. Sorted for determinism.
        public let toDrain: [String]
        /// The new active file to attach the dispatch source to. `nil`
        /// when `currentWatched` is already the latest and no rotation
        /// is needed.
        public let newWatched: String?

        public init(toDrain: [String], newWatched: String?) {
            self.toDrain = toDrain
            self.newWatched = newWatched
        }
    }

    /// Compute the next rotation step for the directory watcher.
    ///
    /// - Parameters:
    ///   - directoryFiles: basenames in the encoded Claude project dir
    ///     (typically from `FileManager.contentsOfDirectory(atPath:)`).
    ///   - dirPath: absolute path of the encoded Claude project dir;
    ///     used to render absolute paths.
    ///   - currentWatched: absolute path of the currently-watched file,
    ///     or `nil` on first start.
    ///   - drainedFiles: paths the watcher has already tailed at least
    ///     once (in-memory, per-process). Files in this set are skipped
    ///     by the drain loop. Caller is responsible for inserting each
    ///     drained path back into the set after `ClaudeSessionTail.tail`
    ///     returns. Prevents O(N²) re-iteration under burst.
    ///   - mtime: closure resolving file mtime. Abstracted so unit tests
    ///     can synthesize ordering without writing real files.
    public static func plan(
        directoryFiles: [String],
        dirPath: String,
        currentWatched: String?,
        drainedFiles: Set<String>,
        mtime: (String) -> Date
    ) -> DrainPlan {
        let jsonl = directoryFiles
            .filter { $0.hasSuffix(".jsonl") && !$0.contains("index") }
            .map { dirPath + "/" + $0 }
        guard !jsonl.isEmpty else { return DrainPlan(toDrain: [], newWatched: nil) }

        let withTimes = jsonl.map { ($0, mtime($0)) }
        guard let latest = withTimes.max(by: { $0.1 < $1.1 })?.0 else {
            return DrainPlan(toDrain: [], newWatched: nil)
        }

        var drainSet = Set<String>()
        for path in jsonl where path != latest && !drainedFiles.contains(path) {
            drainSet.insert(path)
        }
        // Always re-drain the file we're rotating away from. Catches any
        // bytes appended between the last fileSource event and the rotation.
        if let prior = currentWatched, prior != latest, !drainedFiles.contains(prior) {
            drainSet.insert(prior)
        }
        let toDrain = Array(drainSet).sorted()

        let newWatched: String? = (latest == currentWatched) ? nil : latest
        return DrainPlan(toDrain: toDrain, newWatched: newWatched)
    }
}
