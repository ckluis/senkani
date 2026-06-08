import Testing
import Foundation
@testable import Core

/// Coverage for `phase-t6-settings-config-json-writer-2026-06-07`
/// (carve of parent `t6-settings-notifications-matrix-ui-2026-05-21`,
/// acceptance #3).
///
/// The parent's matrix Settings pane will write the operator-edited
/// `NotificationRouter.Config` back to disk. This suite exercises the
/// headless writer that carve added — the SwiftUI pane is the
/// operator-gated remainder and is NOT covered here.
///
/// Personas:
///   - Lauret (Codable round-trip / byte-identity): encode → write file
///     → decode → encode again MUST be byte-identical. A non-determ-
///     inistic encoder (unsorted dictionary keys) would silently churn
///     the on-disk bytes across re-writes; `.sortedKeys` pins them.
///   - Allspaw (back-compat): the writer is purely additive. An
///     existing on-disk config still `loadConfig`s into an equal
///     `Config` after the writer was introduced — the read path and
///     bootstrap behavior are untouched.

private func makeTempPathNCW(_ suffix: String = "json") -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("senkani-notif-cfg-\(UUID().uuidString).\(suffix)")
        .path
}

@Suite("T.6 carve — NotificationRouter.Config JSON writer")
struct NotificationConfigWriterTests {

    /// A representative multi-sink, multi-event config. Multiple sink
    /// keys is the load-bearing case for byte-identity: dictionary
    /// iteration order is not stable across encodes, so only a
    /// `.sortedKeys` encoder makes the bytes reproducible.
    private func representativeConfig() -> NotificationRouter.Config {
        NotificationRouter.Config(sinks: [
            "stdout": .init(events: ["notify_done", "notify_failure", "schedule_end"]),
            "macos_local": .init(events: ["notify_failure", "schedule_end"]),
            "audit_log": .init(events: ["notify_done"]),
        ])
    }

    @Test("Lauret — round-trip is byte-identical: encode → file → decode → encode")
    func roundTripByteIdentical() throws {
        let config = representativeConfig()

        // encode
        let firstBytes = try config.encoded()

        // write to a temp file
        let path = makeTempPathNCW()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try config.save(to: path)

        // the bytes on disk match the in-memory encode exactly
        let onDisk = try #require(FileManager.default.contents(atPath: path))
        #expect(onDisk == firstBytes,
                "save(to:) must write exactly the bytes encoded() produced.")

        // decode from the file
        let decoded = try #require(
            NotificationRouter.loadConfig(from: path),
            "loadConfig must decode the writer's output."
        )
        #expect(decoded == config, "Decoded config must equal the original.")

        // encode again — BYTE-IDENTICAL to the first encode
        let secondBytes = try decoded.encoded()
        #expect(secondBytes == firstBytes,
                "encode(decode(encode(x))) must be byte-identical to encode(x).")
    }

    @Test("Lauret — deterministic across re-encodes regardless of insertion order")
    func deterministicAcrossInsertionOrder() throws {
        // Same logical config, built with sink keys in a different
        // insertion order. A `.sortedKeys` encoder must yield the same
        // bytes for both — proving the byte-identity does not depend on
        // dictionary insertion order.
        let a = NotificationRouter.Config(sinks: [
            "stdout": .init(events: ["notify_done"]),
            "macos_local": .init(events: ["notify_failure"]),
        ])
        let b = NotificationRouter.Config(sinks: [
            "macos_local": .init(events: ["notify_failure"]),
            "stdout": .init(events: ["notify_done"]),
        ])
        #expect(try a.encoded() == b.encoded(),
                "Sorted-keys encoding must be independent of dictionary insertion order.")
    }

    @Test("Allspaw — back-compat: a pre-existing on-disk config still loadConfigs unchanged")
    func backCompatPreExistingConfigLoadsUnchanged() throws {
        // A hand-authored config written BEFORE the writer existed —
        // the exact JSON shape documented in NotificationRouter's
        // header. The writer is additive: this must still decode into
        // the expected Config (read path + decode behavior untouched).
        let legacyJSON = """
        {
          "sinks": {
            "stdout":      { "events": ["notify_done", "notify_failure", "schedule_end"] },
            "macos_local": { "events": ["notify_failure", "schedule_end"] }
          }
        }
        """
        let path = makeTempPathNCW()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try legacyJSON.data(using: .utf8)!.write(to: URL(fileURLWithPath: path))

        let loaded = try #require(
            NotificationRouter.loadConfig(from: path),
            "Pre-existing (pre-writer) config must still loadConfig."
        )
        let expected = NotificationRouter.Config(sinks: [
            "stdout": .init(events: ["notify_done", "notify_failure", "schedule_end"]),
            "macos_local": .init(events: ["notify_failure", "schedule_end"]),
        ])
        #expect(loaded == expected,
                "Adding the writer must not change how an existing config decodes.")
    }

    @Test("Allspaw — loadConfig is unchanged: missing file still returns nil (no throw)")
    func backCompatMissingFileStillNil() {
        let missing = makeTempPathNCW()
        // loadConfig's lenient contract (returns nil, never throws on a
        // missing file) is preserved — only the new save(to:) throws.
        #expect(NotificationRouter.loadConfig(from: missing) == nil)
    }
}
