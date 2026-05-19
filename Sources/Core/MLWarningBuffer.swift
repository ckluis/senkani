import Foundation

/// Per-process JSON-backed buffer of ML model-quality warnings. Used
/// by the PIIClassifier eval gate (T.2b-2) to durably stash a
/// `MODEL_QUALITY_WARNING` line whenever F1 lands in the warn band
/// `[0.90, 0.95)` so the next CHANGELOG draft (manual or via the
/// autonomous loop's CHANGELOG doc-sync) can surface it.
///
/// Buffer file: `~/.senkani/ml-warnings.json`. Tests inject a custom
/// path. The schema is intentionally simple — a JSON array of
/// timestamped entries; readers process latest-first.
///
/// Concurrency: append + read both take an `NSLock`. The buffer is
/// read-and-write per call (no in-memory cache) so concurrent writers
/// from separate processes still produce a coherent on-disk shape —
/// the lock only guards intra-process ordering. Cross-process writers
/// are not coordinated (the eval gate writes from a single process
/// per CI run), so the on-disk file is best-effort under
/// cross-process contention.
public final class MLWarningBuffer: @unchecked Sendable {

    public struct Entry: Codable, Equatable, Sendable {
        public let timestamp: Date
        public let modelId: String
        public let f1: Double
        public let message: String

        public init(timestamp: Date, modelId: String, f1: Double, message: String) {
            self.timestamp = timestamp
            self.modelId = modelId
            self.f1 = f1
            self.message = message
        }
    }

    /// Production default — buffers at `~/.senkani/ml-warnings.json`.
    public static let shared = MLWarningBuffer(path: MLWarningBuffer.defaultPath())

    public let path: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(path: URL) {
        self.path = path
    }

    private static func defaultPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".senkani")
            .appendingPathComponent("ml-warnings.json")
    }

    /// Append one warning entry. Creates the parent directory + file
    /// on first call. Throws on filesystem or encoding failure.
    public func append(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: true
        )
        var entries = try _readUnlocked()
        entries.append(entry)
        let data = try encoder.encode(entries)
        // Atomic-write so a crash mid-write doesn't corrupt the file.
        try data.write(to: path, options: .atomic)
    }

    /// Most recent entry (highest timestamp), or `nil` if the buffer
    /// is empty or the file is missing.
    public func latest() -> Entry? {
        lock.lock(); defer { lock.unlock() }
        guard let entries = try? _readUnlocked() else { return nil }
        return entries.max(by: { $0.timestamp < $1.timestamp })
    }

    /// All buffered entries in write order (oldest first).
    public func all() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return (try? _readUnlocked()) ?? []
    }

    /// Drop the buffer file. Used by tests + the operator after a
    /// CHANGELOG drafts the buffered warnings.
    public func clear() throws {
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func _readUnlocked() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let data = try Data(contentsOf: path)
        guard !data.isEmpty else { return [] }
        return try decoder.decode([Entry].self, from: data)
    }
}
