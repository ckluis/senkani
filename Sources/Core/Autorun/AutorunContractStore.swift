import Foundation

/// U.3 (LEG 1) — `AutorunContractStore`: durable persistence for the
/// decomposed `[WorkstreamTaskContract]` of one autorun run.
///
/// The decomposer's output is written to
/// `~/.senkani/autorun/<run-id>/contracts.json` so an interrupted run can
/// be RESUMED without re-decomposing (the item's "Decomposer output is
/// durable" acceptance bullet). This is the resume seam: write once at
/// plan time, re-read on resume; the loop never re-runs the decomposer
/// for a live run.
///
/// ## Durability shape (Kleppmann)
///
/// The file is encoded with the CANONICAL encoder (`.sortedKeys` +
/// `.iso8601`) — byte-identical re-encode, matching the
/// `WorkstreamTaskContract` round-trip contract — and written
/// atomically (temp-file + rename in the same directory) so a crash mid-
/// write never leaves a half-written `contracts.json` a resume would read
/// as a truncated/corrupt plan. The read path returns nil on a missing or
/// corrupt file rather than throwing past the caller (resume degrades to
/// "no durable plan, re-decompose"), mirroring `PreCompactHandoffLoader`.
///
/// The persisted envelope wraps the contract array with the `runId` and a
/// `schemaVersion` so a future leg can evolve the on-disk shape without
/// silently mis-reading an older file.
public enum AutorunContractStore {

    /// Bumped when the on-disk envelope shape changes. A file written by a
    /// newer schema is treated as "no durable plan" by an older reader
    /// (forward-incompatible reads fail safe to re-decompose).
    ///
    /// v2 (leg 3): the contract gained an optional `task_class`. Old v1 files
    /// stay readable (the version check is `<=`); a v2 file on an older binary
    /// fails safe to re-decompose.
    public static let schemaVersion = 2

    /// The durable on-disk envelope. `Codable` with the canonical encoder.
    public struct Envelope: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let runId: String
        public let contracts: [WorkstreamTaskContract]

        public init(schemaVersion: Int = AutorunContractStore.schemaVersion, runId: String, contracts: [WorkstreamTaskContract]) {
            self.schemaVersion = schemaVersion
            self.runId = runId
            self.contracts = contracts
        }

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case runId = "run_id"
            case contracts
        }
    }

    public enum StoreError: Error, Equatable {
        case write(path: String)
    }

    /// Default autorun root: `~/.senkani/autorun/`. Tests inject an
    /// alternative root so they don't pollute home.
    public static func defaultRootDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".senkani", isDirectory: true)
            .appendingPathComponent("autorun", isDirectory: true)
    }

    /// Directory for a given run: `<root>/<run-id>/`.
    public static func runDir(runId: String, rootDir: URL? = nil) -> URL {
        (rootDir ?? defaultRootDir())
            .appendingPathComponent(safeRunId(runId), isDirectory: true)
    }

    /// The contracts.json path for a run.
    public static func contractsURL(runId: String, rootDir: URL? = nil) -> URL {
        runDir(runId: runId, rootDir: rootDir)
            .appendingPathComponent("contracts.json", isDirectory: false)
    }

    /// Persist the run's contracts atomically. Returns the destination URL.
    @discardableResult
    public static func persist(
        runId: String,
        contracts: [WorkstreamTaskContract],
        rootDir: URL? = nil
    ) throws -> URL {
        let dest = contractsURL(runId: runId, rootDir: rootDir)
        let dir = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let envelope = Envelope(runId: runId, contracts: contracts)
            let data = try canonicalEncoder().encode(envelope)
            // Temp-file + rename in the same dir so the rename is atomic on
            // the same filesystem and a crash mid-write never exposes a
            // partial contracts.json under the canonical name.
            let tmp = dir.appendingPathComponent(".contracts.json.\(UUID().uuidString).tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            return dest
        } catch let err as StoreError {
            throw err
        } catch {
            throw StoreError.write(path: dest.path)
        }
    }

    /// Re-read a run's persisted contracts (the resume seam). Returns nil
    /// on a missing / corrupt / future-schema file — the caller degrades
    /// to re-decomposing rather than crashing.
    public static func load(runId: String, rootDir: URL? = nil) -> [WorkstreamTaskContract]? {
        loadEnvelope(runId: runId, rootDir: rootDir)?.contracts
    }

    /// Re-read the full envelope (schema + runId + contracts). Returns nil
    /// on a missing / corrupt / future-schema file.
    public static func loadEnvelope(runId: String, rootDir: URL? = nil) -> Envelope? {
        let url = contractsURL(runId: runId, rootDir: rootDir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let envelope = try? canonicalDecoder().decode(Envelope.self, from: data) else { return nil }
        // Forward-incompatible read fails safe: a file written by a newer
        // schema is treated as "no durable plan".
        guard envelope.schemaVersion <= schemaVersion else { return nil }
        return envelope
    }

    // MARK: - Helpers

    /// The canonical encoder — `.sortedKeys` + `.iso8601`, matching the
    /// `WorkstreamTaskContract` byte-identical round-trip contract.
    public static func canonicalEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    public static func canonicalDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    /// Sanitize a run id into a single safe path component. Run ids are
    /// expected to be fingerprint-shaped (no separators); we percent-strip
    /// any path-hostile character so a hand-passed `--run-id ../x` can't
    /// escape the autorun root.
    static func safeRunId(_ runId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scrubbed = String(runId.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        // Collapse leading dots so `..` cannot form a parent ref.
        let noLeadingDots = scrubbed.drop { $0 == "." }
        let result = String(noLeadingDots)
        return result.isEmpty ? "run" : result
    }
}
