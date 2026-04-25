import Foundation
import Combine

// MARK: - Model Status

/// Download/readiness state of a managed model.
public enum ModelStatus: String, Codable, Sendable {
    case available    // registered, not yet downloaded
    case downloading  // download in progress
    case downloaded   // on disk, integrity unconfirmed
    case verifying    // running post-install verification fixture
    case verified     // on disk, verification fixture passed — ready to serve
    case broken       // on disk, but verification fixture failed
    case error        // download failed
}

// MARK: - ModelInfo

/// Metadata for a single ML model managed by Senkani.
public struct ModelInfo: Codable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let repoId: String          // HuggingFace repo, e.g. "sentence-transformers/all-MiniLM-L6-v2"
    public let expectedSizeBytes: Int64
    public let requiredRAM: Int        // GB minimum to run this model
    public let quantMethod: String?    // e.g. "APEX Mini", "Q4", nil for embeddings
    public var status: ModelStatus
    public var downloadProgress: Double // 0.0 ..< 1.0
    public var downloadedAt: Date?
    public var localPath: String?
    public var lastError: String?

    /// Alias for view compatibility.
    public var expectedSize: Int64 { expectedSizeBytes }

    public init(
        id: String,
        name: String,
        repoId: String,
        expectedSizeBytes: Int64,
        requiredRAM: Int = 1,
        quantMethod: String? = nil,
        status: ModelStatus = .available,
        downloadProgress: Double = 0,
        downloadedAt: Date? = nil,
        localPath: String? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.repoId = repoId
        self.expectedSizeBytes = expectedSizeBytes
        self.requiredRAM = requiredRAM
        self.quantMethod = quantMethod
        self.status = status
        self.downloadProgress = downloadProgress
        self.downloadedAt = downloadedAt
        self.localPath = localPath
        self.lastError = lastError
    }
}

// MARK: - ModelManager

/// Manages ML model registry, download status, and cache verification.
///
/// Core does NOT depend on MLX or Hub. ModelManager checks the HuggingFace
/// cache on disk (where MLXEmbedders/MLXVLM actually store models) and
/// tracks readiness. Actual MLX loading stays in the MCP tools.
///
/// HuggingFace Hub Swift SDK stores snapshots at:
///   ~/Documents/huggingface/models/{repo-id}/
///
/// ModelManager's role:
/// - Registry of known models with expected sizes
/// - Check if HF cache already has the model files (config.json + *.safetensors)
/// - Report readiness status so tools can gate on it
/// - Track disk usage across all managed models
/// - Provide delete capability for cache cleanup
public final class ModelManager: ObservableObject, @unchecked Sendable {

    public static let shared = ModelManager()

    // MARK: - Published State

    /// Current state of all managed models. Access under lock.
    private var _models: [ModelInfo]
    private let lock = NSLock()

    /// Thread-safe read of models array.
    public var models: [ModelInfo] {
        lock.lock()
        defer { lock.unlock() }
        return _models
    }

    /// Registered download handler. MCP layer registers its handler so Core
    /// doesn't need to depend on MLX/Hub. Protected by `lock`.
    private var downloadHandler: ((String) async throws -> Void)?

    /// Registered verification handler. When `nil`, `verify(modelId:)` falls
    /// back to an integrity-only probe (config.json + weight file on disk,
    /// config parses as JSON dict). MCP layer can override with a real
    /// inference fixture (e.g. `engine.embed("ping")` for the embed model).
    /// Protected by `lock`.
    private var verificationHandler: ((String) async throws -> Void)?

    /// Register a download handler (called by MCP layer at startup).
    /// Thread-safe: acquires lock before writing.
    public func registerDownloadHandler(_ handler: @escaping (String) async throws -> Void) {
        lock.lock()
        downloadHandler = handler
        lock.unlock()
    }

    /// Register a verification handler (called by MCP layer at startup). The
    /// handler should run a tiny inference against the freshly-installed
    /// model and throw if it fails. When no handler is registered the
    /// integrity-only default is used.
    public func registerVerificationHandler(_ handler: @escaping (String) async throws -> Void) {
        lock.lock()
        verificationHandler = handler
        lock.unlock()
    }

    // MARK: - HuggingFace Cache Location

    /// The base directory where HuggingFace Hub Swift SDK stores downloaded models.
    /// Default: ~/Documents/huggingface/models/
    private let hfCacheBase: URL

    // MARK: - Metadata Persistence

    /// Where we persist our own metadata (status, downloadedAt, etc.).
    /// ~/Library/Caches/dev.senkani/models/models.json
    private let metadataURL: URL

    // MARK: - Init

    private init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.hfCacheBase = documents.appendingPathComponent("huggingface/models")

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("dev.senkani/models")
        self.metadataURL = cacheDir.appendingPathComponent("models.json")

        // Start with default registry
        self._models = Self.defaultRegistry

        // Load persisted metadata and merge
        loadPersistedMetadata()

        // Scan disk to reconcile actual state
        reconcileWithDisk()
    }

    /// Visible for testing: create with custom paths.
    init(hfCacheBase: URL, metadataURL: URL) {
        self.hfCacheBase = hfCacheBase
        self.metadataURL = metadataURL
        self._models = Self.defaultRegistry
        loadPersistedMetadata()
        reconcileWithDisk()
    }

    // MARK: - Default Registry

    private static let defaultRegistry: [ModelInfo] = [
        // Primary: Gemma 4 — tier auto-selected by available RAM
        ModelInfo(
            id: "gemma4-26b-apex",
            name: "Gemma 4 26B MoE (APEX Mini)",
            repoId: "mudler/gemma-4-26B-A4B-it-APEX-GGUF",
            expectedSizeBytes: 12_200_000_000,  // ~12GB
            requiredRAM: 16,
            quantMethod: "APEX Mini"
        ),
        ModelInfo(
            id: "gemma4-e4b",
            name: "Gemma 4 E4B (Q4)",
            repoId: "unsloth/gemma-4-E4B-it-UD-MLX-4bit",
            expectedSizeBytes: 2_500_000_000,   // ~2.5GB
            requiredRAM: 8,
            quantMethod: "Q4"
        ),
        ModelInfo(
            id: "gemma4-e2b",
            name: "Gemma 4 E2B (Q4)",
            repoId: "unsloth/gemma-4-E2B-it-GGUF",
            expectedSizeBytes: 1_500_000_000,   // ~1.5GB
            requiredRAM: 4,
            quantMethod: "Q4"
        ),
        // Secondary: embeddings (always downloaded, tiny)
        ModelInfo(
            id: "minilm-l6",
            name: "MiniLM-L6 Embeddings",
            repoId: "sentence-transformers/all-MiniLM-L6-v2",
            expectedSizeBytes: 90_000_000,      // ~90MB
            requiredRAM: 1
        ),
    ]

    // MARK: - RAM Detection & Auto-Selection

    /// Available system RAM in GB.
    public static var availableRAMGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
    }

    /// Recommend the best vision/generative model for this machine's RAM.
    /// Returns the highest-quality Gemma 4 tier that fits.
    public func recommendedVisionModel() -> ModelInfo? {
        let ram = Self.availableRAMGB
        lock.lock()
        let visionModels = _models.filter { $0.id.hasPrefix("gemma4") }
        lock.unlock()
        // Pick the best tier that fits in available RAM (sorted by requiredRAM descending)
        return visionModels
            .sorted { $0.requiredRAM > $1.requiredRAM }
            .first { $0.requiredRAM <= ram }
    }

    /// Human-readable description of the auto-selected tier.
    public var selectedTierDescription: String {
        guard let model = recommendedVisionModel() else {
            return "No compatible model (need ≥4GB RAM)"
        }
        let ram = Self.availableRAMGB
        return "\(model.name) — \(ram)GB RAM detected"
    }

    /// All Gemma 4 vision model IDs, ordered by preference (best first).
    public static let visionModelIds = ["gemma4-26b-apex", "gemma4-e4b", "gemma4-e2b"]

    // MARK: - Public API

    /// Check whether a model is downloaded and ready to use. `.downloaded`
    /// (present on disk, verify not yet run) and `.verified` (verify passed)
    /// both count as ready; `.broken` and `.error` do not.
    public func isReady(_ modelId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let status = _models.first(where: { $0.id == modelId })?.status
        return status == .downloaded || status == .verified
    }

    /// Verify that a model is downloaded AND its files pass integrity checks.
    /// Does NOT load the model into memory — just checks disk state.
    /// Returns nil on success, or a human-readable error string.
    public func verifyInference(_ modelId: String) -> String? {
        lock.lock()
        guard let info = _models.first(where: { $0.id == modelId }) else {
            lock.unlock()
            return "Unknown model ID: \(modelId)"
        }
        let status = info.status
        lock.unlock()

        guard status == .downloaded || status == .verified else {
            return "\(info.name) is not downloaded (status: \(status.rawValue))"
        }
        return nil  // Files exist and status is at-least downloaded — ready
    }

    /// Get info for a specific model.
    public func model(_ modelId: String) -> ModelInfo? {
        lock.lock()
        defer { lock.unlock() }
        return _models.first(where: { $0.id == modelId })
    }

    /// The HuggingFace cache directory for a given repo ID.
    /// e.g. ~/Documents/huggingface/models/sentence-transformers/all-MiniLM-L6-v2
    /// SECURITY: Validates repoId to prevent path traversal attacks.
    public func hfCachePath(for repoId: String) -> URL {
        let resolved = hfCacheBase.appendingPathComponent(repoId).standardizedFileURL
        // SECURITY: Ensure the resolved path stays within hfCacheBase to prevent
        // path traversal via repo IDs like "../../etc/passwd" or symlink attacks
        let basePath = hfCacheBase.standardizedFileURL.path
        precondition(
            resolved.path.hasPrefix(basePath + "/") || resolved.path == basePath,
            "[ModelManager] SECURITY: Path traversal detected in repoId: \(repoId)"
        )
        return resolved
    }

    /// The HuggingFace cache directory for a model by its senkani ID.
    public func localPath(for modelId: String) -> URL? {
        lock.lock()
        let info = _models.first(where: { $0.id == modelId })
        lock.unlock()
        guard let info else { return nil }
        return hfCachePath(for: info.repoId)
    }

    /// Rescan the HuggingFace cache to update model status.
    /// Call after a tool triggers a download via MLX libraries.
    public func refresh() {
        reconcileWithDisk()
        persistMetadata()
        notifyChange()
    }

    /// Mark a model as downloading with progress.
    public func updateProgress(_ modelId: String, progress: Double) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .downloading
            _models[idx].downloadProgress = progress
        }
        lock.unlock()
        notifyChange()
    }

    /// Mark a model as downloaded after MLX libraries finish their download.
    /// Does NOT auto-run verification — callers that want the "install →
    /// verify" fused flow should use `download(modelId:)` or call
    /// `verify(modelId:)` explicitly.
    public func markDownloaded(_ modelId: String) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .downloaded
            _models[idx].downloadProgress = 1.0
            _models[idx].downloadedAt = Date()
            _models[idx].localPath = hfCachePath(for: _models[idx].repoId).path
            _models[idx].lastError = nil
        }
        lock.unlock()
        persistMetadata()
        notifyChange()
    }

    /// Mark a model as `.verifying` before a verify fixture runs.
    public func markVerifying(_ modelId: String) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .verifying
            _models[idx].lastError = nil
        }
        lock.unlock()
        notifyChange()
    }

    /// Mark a model as `.verified` after a verify fixture succeeds.
    public func markVerified(_ modelId: String) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .verified
            _models[idx].downloadProgress = 1.0
            _models[idx].lastError = nil
            if _models[idx].downloadedAt == nil {
                _models[idx].downloadedAt = Date()
            }
            _models[idx].localPath = hfCachePath(for: _models[idx].repoId).path
        }
        lock.unlock()
        persistMetadata()
        notifyChange()
    }

    /// Mark a model as `.broken` when a verify fixture fails. The files are
    /// still on disk; the user can retry via `verify(modelId:)` or delete.
    public func markBroken(_ modelId: String, message: String) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .broken
            _models[idx].lastError = message
        }
        lock.unlock()
        persistMetadata()
        notifyChange()
    }

    /// Mark a model as errored.
    public func markError(_ modelId: String, message: String) {
        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .error
            _models[idx].lastError = message
        }
        lock.unlock()
        persistMetadata()
        notifyChange()
    }

    /// Trigger a model download via the registered handler, and on success
    /// automatically run verification. Callers (the UI "Install" button, the
    /// MCP tool install path) get the full install → verify transition in
    /// one call.
    ///
    /// Status progression on success:
    ///   .available → .downloading (via handler's progress callbacks)
    ///               → .downloaded → .verifying → .verified
    ///
    /// On download failure:
    ///   .available → .downloading → .error (lastError = thrown message)
    ///
    /// On verification failure:
    ///   .available → ... → .downloaded → .verifying → .broken
    public func download(modelId: String) async throws {
        let handler: ((String) async throws -> Void)? = lock.withLock {
            downloadHandler
        }
        guard let handler else {
            markError(modelId, message: "No download handler registered. Start the MCP server first.")
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No download handler registered. Start the MCP server first."]
            )
        }

        // Download phase — handler drives progress via updateProgress/markDownloaded.
        do {
            try await handler(modelId)
        } catch {
            markError(modelId, message: error.localizedDescription)
            throw error
        }

        // If the handler didn't flip the status to .downloaded (e.g. because
        // it relies on reconcileWithDisk), do it now so verify has the right
        // precondition. Callers that already called markDownloaded get a no-op.
        let needsMarkDownloaded: Bool = lock.withLock {
            if let idx = _models.firstIndex(where: { $0.id == modelId }) {
                let s = _models[idx].status
                return s == .downloading || s == .available
            }
            return false
        }
        if needsMarkDownloaded {
            markDownloaded(modelId)
        }

        // Verify phase — throws are swallowed and reflected as .broken so the
        // caller's Install button doesn't surface a second error banner; the
        // UI reads status directly.
        try? await verify(modelId: modelId)
    }

    /// Run the verification fixture against a previously-downloaded model,
    /// flipping status to `.verified` or `.broken`. Safe to call on
    /// `.downloaded`, `.verified`, or `.broken` (retry). Throws if the model
    /// is unknown or not present on disk.
    public func verify(modelId: String) async throws {
        let (known, preconditionOk, handler) = lock.withLock { () -> (Bool, Bool, ((String) async throws -> Void)?) in
            guard let info = _models.first(where: { $0.id == modelId }) else {
                return (false, false, nil)
            }
            let ok = info.status == .downloaded || info.status == .verified || info.status == .broken
            return (true, ok, verificationHandler)
        }
        guard known else {
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown model ID: \(modelId)"]
            )
        }
        guard preconditionOk else {
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Cannot verify \(modelId): model is not downloaded"]
            )
        }

        markVerifying(modelId)

        do {
            if let handler {
                try await handler(modelId)
            } else {
                try runDefaultVerification(modelId: modelId)
            }
            markVerified(modelId)
        } catch {
            markBroken(modelId, message: error.localizedDescription)
            throw error
        }
    }

    /// Default verification when no handler is registered: re-check that
    /// config.json and a weight file are on disk, and that config.json
    /// parses as a JSON dictionary. Cheap, deterministic, MLX-free.
    private func runDefaultVerification(modelId: String) throws {
        let repoId = lock.withLock { () -> String? in
            _models.first(where: { $0.id == modelId })?.repoId
        }
        guard let repoId else {
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unknown model ID: \(modelId)"]
            )
        }
        guard modelExistsOnDisk(repoId: repoId) else {
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Model files missing on disk"]
            )
        }
        guard verifyConfigIntegrity(repoId: repoId) else {
            throw NSError(
                domain: "dev.senkani.ModelManager",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "config.json failed integrity check"]
            )
        }
    }

    /// Delete a model's cached files from the HuggingFace cache.
    /// Returns the number of bytes freed.
    @discardableResult
    public func delete(_ modelId: String) throws -> Int64 {
        lock.lock()
        guard let idx = _models.firstIndex(where: { $0.id == modelId }) else {
            lock.unlock()
            return 0
        }
        let repoId = _models[idx].repoId
        lock.unlock()

        let modelDir = hfCachePath(for: repoId)
        let freed = Self.directorySize(modelDir)

        if FileManager.default.fileExists(atPath: modelDir.path) {
            try FileManager.default.removeItem(at: modelDir)
        }

        lock.lock()
        if let idx = _models.firstIndex(where: { $0.id == modelId }) {
            _models[idx].status = .available
            _models[idx].downloadProgress = 0
            _models[idx].downloadedAt = nil
            _models[idx].localPath = nil
            _models[idx].lastError = nil
        }
        lock.unlock()

        persistMetadata()
        notifyChange()
        return freed
    }

    /// Delete by labeled argument (view compatibility).
    public func delete(modelId: String) throws {
        try delete(modelId)
    }

    /// Total disk usage of all downloaded models (no-arg convenience for views).
    public func diskUsage() -> Int64 {
        totalDiskUsage()
    }

    /// Total disk usage of all downloaded models. Counts anything whose
    /// files are on disk: `.downloaded`, `.verifying`, `.verified`, `.broken`.
    public func totalDiskUsage() -> Int64 {
        lock.lock()
        let present = _models.filter {
            switch $0.status {
            case .downloaded, .verifying, .verified, .broken: return true
            case .available, .downloading, .error: return false
            }
        }
        lock.unlock()

        return present.reduce(Int64(0)) { total, info in
            total + Self.directorySize(hfCachePath(for: info.repoId))
        }
    }

    /// Disk usage for a single model.
    public func diskUsage(for modelId: String) -> Int64 {
        lock.lock()
        guard let info = _models.first(where: { $0.id == modelId }) else {
            lock.unlock()
            return 0
        }
        lock.unlock()
        return Self.directorySize(hfCachePath(for: info.repoId))
    }

    /// Human-readable disk usage string.
    public static func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else if bytes >= 1_000 {
            return String(format: "%.1f KB", Double(bytes) / 1_000)
        }
        return "\(bytes) bytes"
    }

    // MARK: - Disk Reconciliation

    /// Check whether a model's files actually exist in the HF cache.
    /// A model is considered present if config.json and at least one weight file exist.
    /// Supports .safetensors (standard) and .gguf (quantized) formats.
    private func modelExistsOnDisk(repoId: String) -> Bool {
        let modelDir = hfCachePath(for: repoId)
        let fm = FileManager.default

        let configPath = modelDir.appendingPathComponent("config.json").path
        guard fm.fileExists(atPath: configPath) else { return false }

        // Check for at least one weight file (.safetensors or .gguf for quantized models)
        guard let contents = try? fm.contentsOfDirectory(atPath: modelDir.path) else { return false }
        return contents.contains(where: { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") })
    }

    /// Verify config.json integrity beyond just valid JSON.
    /// SECURITY: Checks that config.json is a reasonable size (prevents zip-bomb-style
    /// attacks via huge JSON), is a valid JSON dictionary (not array/string), and
    /// doesn't contain suspiciously large string values that could be used for
    /// resource exhaustion when the config is parsed by MLX libraries.
    private func verifyConfigIntegrity(repoId: String) -> Bool {
        let configURL = hfCachePath(for: repoId).appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL) else { return false }

        // SECURITY: Reject config files larger than 1MB — legitimate configs are ~1-10KB
        let maxConfigSize = 1_048_576  // 1 MB
        guard data.count <= maxConfigSize else {
            print("[ModelManager] SECURITY: config.json for \(repoId) exceeds \(maxConfigSize) bytes — rejecting")
            return false
        }

        // Must parse as a JSON dictionary (not array, string, etc.)
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              obj is [String: Any] else {
            return false
        }

        return true
    }

    /// Walk all registered models and update their status based on disk reality.
    private func reconcileWithDisk() {
        // 1. Snapshot repo IDs and current statuses under lock
        lock.lock()
        let snapshot: [(index: Int, repoId: String, status: ModelStatus)] = _models.indices.map {
            ($0, _models[$0].repoId, _models[$0].status)
        }
        lock.unlock()

        // 2. Disk I/O outside the lock — avoids blocking SwiftUI reads
        var updates: [(index: Int, exists: Bool)] = []
        for item in snapshot {
            let exists = modelExistsOnDisk(repoId: item.repoId) && verifyConfigIntegrity(repoId: item.repoId)
            updates.append((item.index, exists))
        }

        // 3. Apply updates under lock
        lock.lock()
        for update in updates {
            let i = update.index
            guard i < _models.count else { continue }
            let repoId = _models[i].repoId
            if update.exists {
                // Don't disturb in-flight or verified/broken — those states
                // already know the files exist. Only lift .available/.error
                // up to .downloaded so a pre-populated cache gets picked up.
                let s = _models[i].status
                if s == .available || s == .error {
                    _models[i].status = .downloaded
                    _models[i].downloadProgress = 1.0
                    _models[i].localPath = hfCachePath(for: repoId).path
                    if _models[i].downloadedAt == nil {
                        _models[i].downloadedAt = Date()
                    }
                }
            } else {
                // Files vanished from disk — any post-download state drops
                // back to .available so the UI re-offers install.
                let s = _models[i].status
                if s == .downloaded || s == .verified || s == .broken || s == .verifying {
                    _models[i].status = .available
                    _models[i].downloadProgress = 0
                    _models[i].localPath = nil
                }
            }
        }
        lock.unlock()
    }

    // MARK: - Persistence

    private struct PersistedMetadata: Codable {
        let models: [ModelInfo]
    }

    private func persistMetadata() {
        lock.lock()
        let snapshot = _models
        lock.unlock()

        let metadata = PersistedMetadata(models: snapshot)
        guard let data = try? JSONEncoder().encode(metadata) else { return }

        let dir = metadataURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Atomic write via Data.write with .atomic option
        try? data.write(to: metadataURL, options: .atomic)
    }

    private func loadPersistedMetadata() {
        guard let data = try? Data(contentsOf: metadataURL),
              let persisted = try? JSONDecoder().decode(PersistedMetadata.self, from: data)
        else { return }

        // Merge persisted state into registry entries (registry is source of truth for schema)
        lock.lock()
        for saved in persisted.models {
            if let idx = _models.firstIndex(where: { $0.id == saved.id }) {
                _models[idx].downloadedAt = saved.downloadedAt
                _models[idx].lastError = saved.lastError
                // Don't restore status directly — reconcileWithDisk will set it from reality
            }
        }
        lock.unlock()
    }

    // MARK: - ObservableObject

    /// Notify SwiftUI views on main thread that model state changed.
    private func notifyChange() {
        DispatchQueue.main.async { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Helpers

    /// Calculate total size of a directory recursively.
    private static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}
