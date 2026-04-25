import Testing
import Foundation
@testable import Core

/// Tests for the Models pane install → verify state machine.
///
/// Sub-item `models-page-installable` (2026-04-20). Exercises:
///   - Happy path: .available → .downloading → .downloaded → .verifying → .verified
///   - Failed download: .downloading → .error + lastError set
///   - Failed verify: .downloaded → .verifying → .broken + lastError set
///   - Delete-and-reinstall: .verified → (delete) → .available → install → .verified
///   - Retry verify on broken: .broken → .verified
///
/// Fake handlers let us drive the state machine without MLX dependencies.
/// A temp HF cache dir with a canned config.json + dummy safetensors lets
/// the integrity-only default verification pass.
@Suite("Model install state machine")
struct ModelManagerInstallTests {

    /// Spin up a ModelManager pointed at a temp HF cache + metadata file.
    /// Returns (manager, hfRoot) — caller cleans up hfRoot via tempDir deletion.
    private func makeManager() -> (ModelManager, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-install-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let hfRoot = tempDir.appendingPathComponent("hf")
        let metadataURL = tempDir.appendingPathComponent("meta.json")
        try? FileManager.default.createDirectory(at: hfRoot, withIntermediateDirectories: true)
        return (ModelManager(hfCacheBase: hfRoot, metadataURL: metadataURL), hfRoot)
    }

    // MARK: - 1. Happy path

    @Test("happy path drives status through downloading → downloaded → verified")
    func happyPathReachesVerified() async throws {
        let (mgr, hfRoot) = makeManager()
        let modelId = "minilm-l6"  // default registry entry

        // Download handler plants weights on disk + reports progress
        // so the UI can render a bar during `.downloading`.
        mgr.registerDownloadHandler { [hfRoot] id in
            mgr.updateProgress(id, progress: 0.25)
            mgr.updateProgress(id, progress: 0.75)
            // Plant weights so integrity-only verify can pass.
            guard let info = mgr.model(id) else { return }
            try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
            mgr.markDownloaded(id)
        }

        try await mgr.download(modelId: modelId)

        let final = try #require(mgr.model(modelId))
        #expect(final.status == .verified)
        #expect(final.downloadProgress == 1.0)
        #expect(final.localPath != nil)
        #expect(final.lastError == nil)
        #expect(mgr.isReady(modelId))
    }

    // MARK: - 2. Download failure

    @Test("download failure stops the machine at .error + surfaces lastError")
    func downloadFailureFlipsToError() async throws {
        let (mgr, _) = makeManager()
        let modelId = "gemma4-e2b"

        mgr.registerDownloadHandler { _ in
            throw NSError(
                domain: "test",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "network down"]
            )
        }

        await #expect(throws: Error.self) {
            try await mgr.download(modelId: modelId)
        }

        let after = try #require(mgr.model(modelId))
        #expect(after.status == .error)
        #expect(after.lastError?.contains("network down") == true)
        #expect(!mgr.isReady(modelId))
    }

    // MARK: - 3. Verification failure

    @Test("verification failure flips to .broken and keeps files on disk")
    func verifyFailureFlipsToBroken() async throws {
        let (mgr, hfRoot) = makeManager()
        let modelId = "minilm-l6"

        mgr.registerDownloadHandler { [hfRoot] id in
            guard let info = mgr.model(id) else { return }
            try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
            mgr.markDownloaded(id)
        }
        // Fake inference fixture — blows up on first probe.
        mgr.registerVerificationHandler { _ in
            throw NSError(
                domain: "test",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "cannot load weights"]
            )
        }

        try await mgr.download(modelId: modelId)

        let after = try #require(mgr.model(modelId))
        #expect(after.status == .broken)
        #expect(after.lastError?.contains("cannot load weights") == true)
        // Files still on disk — user can retry or delete.
        let info = try #require(mgr.model(modelId))
        let modelDir = hfRoot.appendingPathComponent(info.repoId)
        #expect(FileManager.default.fileExists(atPath: modelDir.path))
        // `isReady` excludes .broken.
        #expect(!mgr.isReady(modelId))
    }

    // MARK: - 4. Delete + reinstall round-trip

    @Test("delete frees disk, resets status, and re-install reaches .verified again")
    func deleteThenReinstallRoundTrips() async throws {
        let (mgr, hfRoot) = makeManager()
        let modelId = "minilm-l6"

        mgr.registerDownloadHandler { [hfRoot] id in
            guard let info = mgr.model(id) else { return }
            try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
            mgr.markDownloaded(id)
        }
        // No verification handler → integrity-only default (passes because
        // planted config + safetensors satisfy verifyConfigIntegrity).

        try await mgr.download(modelId: modelId)
        #expect(mgr.model(modelId)?.status == .verified)

        let freed = try mgr.delete(modelId)
        #expect(freed > 0)
        let afterDelete = try #require(mgr.model(modelId))
        #expect(afterDelete.status == .available)
        #expect(afterDelete.downloadProgress == 0)
        #expect(afterDelete.localPath == nil)
        let info = try #require(mgr.model(modelId))
        let modelDir = hfRoot.appendingPathComponent(info.repoId)
        #expect(!FileManager.default.fileExists(atPath: modelDir.path))

        // Re-install — must reach .verified again.
        try await mgr.download(modelId: modelId)
        #expect(mgr.model(modelId)?.status == .verified)
    }

    // MARK: - 5. Retry verify after broken

    @Test("explicit verify retry flips .broken back to .verified when the fixture succeeds")
    func retryVerifyRescuesBroken() async throws {
        let (mgr, hfRoot) = makeManager()
        let modelId = "minilm-l6"

        // First verify throws, second succeeds — simulates transient OOM.
        let attempt = Atomic(0)
        mgr.registerDownloadHandler { [hfRoot] id in
            guard let info = mgr.model(id) else { return }
            try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
            mgr.markDownloaded(id)
        }
        mgr.registerVerificationHandler { _ in
            let n = attempt.increment()
            if n == 1 {
                throw NSError(
                    domain: "test",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "transient failure"]
                )
            }
            // n == 2 → succeed
        }

        try await mgr.download(modelId: modelId)
        #expect(mgr.model(modelId)?.status == .broken)

        // Explicit retry.
        try await mgr.verify(modelId: modelId)
        #expect(mgr.model(modelId)?.status == .verified)
        #expect(mgr.model(modelId)?.lastError == nil)
    }

    // MARK: - 6. Doctor integration (per-model status read)

    @Test("doctor-style per-model readout surfaces .verified / .broken / .available distinctly")
    func doctorReadsPerModelStatus() async throws {
        let (mgr, hfRoot) = makeManager()

        // minilm-l6 → happy path → .verified
        mgr.registerDownloadHandler { [hfRoot] id in
            guard let info = mgr.model(id) else { return }
            if id == "minilm-l6" {
                try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
                mgr.markDownloaded(id)
            }
        }
        try await mgr.download(modelId: "minilm-l6")

        // gemma4-e2b → install succeeds but verify blows up → .broken.
        // Use a per-id verify handler so minilm-l6 above stayed .verified
        // (re-registering would not retroactively break it — status is
        // already .verified by this point).
        mgr.registerVerificationHandler { id in
            if id == "gemma4-e2b" {
                throw NSError(
                    domain: "test",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "weights incompatible with runtime"]
                )
            }
        }
        mgr.registerDownloadHandler { [hfRoot] id in
            guard let info = mgr.model(id) else { return }
            try plantWeightsOnDisk(at: hfRoot, repoId: info.repoId)
            mgr.markDownloaded(id)
        }
        try await mgr.download(modelId: "gemma4-e2b")

        // gemma4-e4b → never installed → .available
        let statuses = Dictionary(
            uniqueKeysWithValues: mgr.models.map { ($0.id, $0.status) }
        )
        #expect(statuses["minilm-l6"] == .verified)
        #expect(statuses["gemma4-e2b"] == .broken)
        #expect(statuses["gemma4-e4b"] == .available)
        // The doctor check reads this exact same `mgr.models` snapshot — so
        // if this test passes, doctor's per-model readout is correct.
    }

    // MARK: - 7. No download handler guard

    @Test("download without a registered handler flips to .error with actionable message")
    func missingDownloadHandlerSurfacesError() async throws {
        let (mgr, _) = makeManager()

        await #expect(throws: Error.self) {
            try await mgr.download(modelId: "minilm-l6")
        }

        let after = try #require(mgr.model("minilm-l6"))
        #expect(after.status == .error)
        #expect(after.lastError?.contains("handler") == true)
    }
}

// MARK: - Fixtures

/// Plant a minimal HF snapshot (config.json + dummy weight file) so the
/// integrity-only default verifier accepts it. File-scope so multiple
/// `@Suite` structs can share if we add more later.
fileprivate func plantWeightsOnDisk(at hfRoot: URL, repoId: String) throws {
    let modelDir = hfRoot.appendingPathComponent(repoId)
    try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
    let config = #"{"model_type":"test","hidden_size":64}"#.data(using: .utf8)!
    try config.write(to: modelDir.appendingPathComponent("config.json"))
    try Data(repeating: 0, count: 32)
        .write(to: modelDir.appendingPathComponent("model.safetensors"))
}

/// Tiny thread-safe counter for the retry test — NSLock-based to avoid
/// pulling in Swift atomics.
fileprivate final class Atomic: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ initial: Int) { self.value = initial }
    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
