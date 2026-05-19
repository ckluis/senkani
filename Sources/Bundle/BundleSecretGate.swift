import Foundation
import Core

// MARK: - U.10a-2 — ContextManifest secret gate
//
// Layers the refusal + override + chained audit-row behavior on top of
// `BundleComposer.composeManifest()`. The producer (U.10a-1) stays
// pure — it walks inputs, scans content via `SecretDetector.scan`, and
// flips an item's `sensitivity` to `.flagged` whenever the underlying
// source had a pattern hit. This file adds the policy on top:
//
//   - `composeManifestGated(...)` calls `composeManifest`, then
//     walks the result for `.flagged` items. If any are present AND
//     the caller did not pass `allowSecrets: true`, throw
//     `ManifestSecretGateError` — the offending lane set + count
//     are in the error so callers can render a clean refusal
//     without exposing the secret content.
//
//   - On override (`allowSecrets: true`) the gate fires exactly one
//     `bundle.secret.allow` audit row via the injected
//     `BundleAuditRecorder`. The row goes through
//     `recordTokenEvent`'s standard T.5 chain path so
//     `senkani doctor --verify-chain` covers it.
//
//   - Every call (preview or materialized dispatch, override or not)
//     also fires one `bundle.dispatch` audit row with per-lane and
//     per-mode item counts + total estimated tokens. The row is the
//     "what was about to be sent" record for after-the-fact review.
//
// The recorder is a protocol so tests can substitute a temp-DB
// implementation without standing up `SessionDatabase.shared`.
// Mirrors `CredentialGateway.Recorder` / `LiveRecorder` /
// `DatabaseRecorder` from T.4b.

/// Refusal returned when the manifest carries flagged items and the
/// caller did not pass `allowSecrets: true`. The description includes
/// the offending lane set and count — never the secret content itself.
public struct ManifestSecretGateError: Error, CustomStringConvertible, Sendable, Equatable {
    public let lanesWithHits: [String]
    public let itemCount: Int

    public init(lanesWithHits: [String], itemCount: Int) {
        self.lanesWithHits = lanesWithHits
        self.itemCount = itemCount
    }

    public var description: String {
        let lanes = lanesWithHits.joined(separator: ",")
        return "ContextManifest refusal: \(itemCount) item(s) carry SecretDetector hits in lanes [\(lanes)]. Pass --allow-secrets (CLI) or allow_secrets:true (MCP) to override; every override fires a chained bundle.secret.allow audit row."
    }
}

/// Recorder seam — production wires `LiveBundleAuditRecorder` (writes
/// to `SessionDatabase.shared.recordTokenEvent`). Tests pass a
/// `DatabaseBundleAuditRecorder` backed by a temp DB and read the row
/// back to assert shape + chain integrity.
public protocol BundleAuditRecorder: Sendable {
    func recordSecretAllow(
        itemCount: Int,
        lanesWithHits: [String],
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    )

    func recordDispatch(
        preview: Bool,
        perLane: [String: Int],
        perMode: [String: Int],
        tokensEstimated: Int,
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    )
}

/// Production recorder — routes to `SessionDatabase.shared`.
public struct LiveBundleAuditRecorder: BundleAuditRecorder {
    public init() {}

    public func recordSecretAllow(
        itemCount: Int,
        lanesWithHits: [String],
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    ) {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "bundle.secret.allow",
            command: BundleAuditPayloads.secretAllow(
                itemCount: itemCount,
                lanesWithHits: lanesWithHits,
                toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordDispatch(
        preview: Bool,
        perLane: [String: Int],
        perMode: [String: Int],
        tokensEstimated: Int,
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    ) {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "bundle.dispatch",
            command: BundleAuditPayloads.dispatch(
                preview: preview,
                perLane: perLane,
                perMode: perMode,
                tokensEstimated: tokensEstimated,
                toolId: toolId
            ),
            modelTier: nil
        )
    }
}

/// Database-backed recorder for tests. Identical payload shape as
/// `LiveBundleAuditRecorder` so tests assert against production shape.
public struct DatabaseBundleAuditRecorder: BundleAuditRecorder {
    public let database: SessionDatabase

    public init(database: SessionDatabase) {
        self.database = database
    }

    public func recordSecretAllow(
        itemCount: Int,
        lanesWithHits: [String],
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    ) {
        database.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "bundle.secret.allow",
            command: BundleAuditPayloads.secretAllow(
                itemCount: itemCount,
                lanesWithHits: lanesWithHits,
                toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordDispatch(
        preview: Bool,
        perLane: [String: Int],
        perMode: [String: Int],
        tokensEstimated: Int,
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    ) {
        database.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "bundle.dispatch",
            command: BundleAuditPayloads.dispatch(
                preview: preview,
                perLane: perLane,
                perMode: perMode,
                tokensEstimated: tokensEstimated,
                toolId: toolId
            ),
            modelTier: nil
        )
    }
}

/// Canonical `command`-column payloads. Compact JSON with sorted keys
/// — the manifest schema is the truth; this column is the audit
/// breadcrumb. Never carries secret content (only counts + lane names
/// + the caller's `toolId`).
public enum BundleAuditPayloads {

    public static func secretAllow(
        itemCount: Int,
        lanesWithHits: [String],
        toolId: String?
    ) -> String {
        var dict: [String: Any] = [
            "item_count": itemCount,
            "lanes_with_hits": lanesWithHits,
        ]
        if let toolId { dict["tool_id"] = toolId }
        return encode(dict)
    }

    public static func dispatch(
        preview: Bool,
        perLane: [String: Int],
        perMode: [String: Int],
        tokensEstimated: Int,
        toolId: String?
    ) -> String {
        var dict: [String: Any] = [
            "preview": preview,
            "per_lane": perLane,
            "per_mode": perMode,
            "tokens_estimated_total": tokensEstimated,
        ]
        if let toolId { dict["tool_id"] = toolId }
        return encode(dict)
    }

    private static func encode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.sortedKeys])
        else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension BundleComposer {

    /// Compose a manifest with the U.10a-2 secret gate applied.
    ///
    /// - Parameters:
    ///   - options: identical to `composeManifest`.
    ///   - inputs: identical to `composeManifest`.
    ///   - allowSecrets: when false (default), any `.flagged` item
    ///     causes the call to throw `ManifestSecretGateError`. When
    ///     true, the call succeeds and one `bundle.secret.allow`
    ///     audit row fires through `recorder` (if non-nil).
    ///   - preview: true for `--preview` / `preview:true` callers;
    ///     false for materialized dispatch. Carried in the
    ///     `bundle.dispatch` audit-row payload so reviewers can
    ///     distinguish "audit only" from "shipped" rows.
    ///   - recorder: optional. Production: pass
    ///     `LiveBundleAuditRecorder()`. Tests: pass
    ///     `DatabaseBundleAuditRecorder(database:)`.
    ///   - sessionId / projectRoot: pass-through for the audit-row's
    ///     `session_id` / `project_root` columns.
    /// - Returns: the manifest (unchanged from `composeManifest`).
    /// - Throws: `ManifestSecretGateError` if any item is `.flagged`
    ///   and `allowSecrets` is false. The dispatch audit row does
    ///   NOT fire on refusal — the row's purpose is the "what was
    ///   sent" trail, and nothing was sent.
    public static func composeManifestGated(
        options: ManifestOptions,
        inputs: BundleInputs,
        allowSecrets: Bool,
        preview: Bool,
        recorder: BundleAuditRecorder?,
        sessionId: String? = nil,
        projectRoot: String? = nil
    ) throws -> ContextManifest {
        let manifest = composeManifest(options: options, inputs: inputs)

        let flagged = manifest.items.filter { $0.sensitivity == .flagged }
        if !flagged.isEmpty && !allowSecrets {
            let lanes = Array(Set(flagged.map { $0.lane.rawValue })).sorted()
            throw ManifestSecretGateError(
                lanesWithHits: lanes, itemCount: flagged.count)
        }

        if !flagged.isEmpty && allowSecrets {
            let lanes = Array(Set(flagged.map { $0.lane.rawValue })).sorted()
            recorder?.recordSecretAllow(
                itemCount: flagged.count,
                lanesWithHits: lanes,
                toolId: options.toolId,
                sessionId: sessionId,
                projectRoot: projectRoot
            )
        }

        recorder?.recordDispatch(
            preview: preview,
            perLane: manifest.counts.perLane,
            perMode: manifest.counts.perMode,
            tokensEstimated: manifest.counts.tokensEstimatedTotal,
            toolId: options.toolId,
            sessionId: sessionId,
            projectRoot: projectRoot
        )

        return manifest
    }
}
