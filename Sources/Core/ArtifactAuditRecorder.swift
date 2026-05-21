import Foundation

// MARK: - V.9a — ArtifactAuditRecorder
//
// Mirrors BundleAuditRecorder (U.10a-2). Three event kinds fire
// through this recorder:
//
//   - artifact.read            — every successful `ArtifactStore.read`.
//   - artifact.secret.allow    — every `read` with allowSecrets=true AND
//                                SecretDetector hit. Chained per T.5.
//   - artifact.versions        — every `ArtifactStore.versions(of:)`.
//
// Production wires `LiveArtifactAuditRecorder` (SessionDatabase.shared).
// Tests pass `DatabaseArtifactAuditRecorder(database:)` backed by a
// temp DB so chain integrity can be asserted without standing up
// the shared singleton.
//
// Payload column shapes — JSON, sorted keys, no offending content.

public protocol ArtifactAuditRecorder: Sendable {
    func recordRead(
        artifactId: String,
        sourcePane: String,
        allowedSecrets: Bool,
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    )

    func recordSecretAllow(
        artifactId: String,
        sourcePane: String,
        hitCount: Int,
        hitPatternNames: [String],
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    )

    func recordVersions(
        artifactId: String,
        sourcePane: String,
        count: Int,
        toolId: String?,
        sessionId: String?,
        projectRoot: String?
    )
}

// MARK: - Live (SessionDatabase.shared)

public struct LiveArtifactAuditRecorder: ArtifactAuditRecorder {
    public init() {}

    public func recordRead(
        artifactId: String, sourcePane: String, allowedSecrets: Bool,
        toolId: String?, sessionId: String?, projectRoot: String?
    ) {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.read",
            command: ArtifactAuditPayloads.read(
                artifactId: artifactId,
                sourcePane: sourcePane,
                allowedSecrets: allowedSecrets,
                toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordSecretAllow(
        artifactId: String, sourcePane: String, hitCount: Int,
        hitPatternNames: [String], toolId: String?,
        sessionId: String?, projectRoot: String?
    ) {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.secret.allow",
            command: ArtifactAuditPayloads.secretAllow(
                artifactId: artifactId,
                sourcePane: sourcePane,
                hitCount: hitCount,
                hitPatternNames: hitPatternNames,
                toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordVersions(
        artifactId: String, sourcePane: String, count: Int,
        toolId: String?, sessionId: String?, projectRoot: String?
    ) {
        SessionDatabase.shared.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil,
            projectRoot: projectRoot,
            source: "audit",
            toolName: toolId,
            model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.versions",
            command: ArtifactAuditPayloads.versions(
                artifactId: artifactId,
                sourcePane: sourcePane,
                count: count,
                toolId: toolId
            ),
            modelTier: nil
        )
    }
}

// MARK: - Database-backed (tests)

public struct DatabaseArtifactAuditRecorder: ArtifactAuditRecorder {
    public let database: SessionDatabase
    public init(database: SessionDatabase) { self.database = database }

    public func recordRead(
        artifactId: String, sourcePane: String, allowedSecrets: Bool,
        toolId: String?, sessionId: String?, projectRoot: String?
    ) {
        database.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil, projectRoot: projectRoot, source: "audit",
            toolName: toolId, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.read",
            command: ArtifactAuditPayloads.read(
                artifactId: artifactId, sourcePane: sourcePane,
                allowedSecrets: allowedSecrets, toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordSecretAllow(
        artifactId: String, sourcePane: String, hitCount: Int,
        hitPatternNames: [String], toolId: String?,
        sessionId: String?, projectRoot: String?
    ) {
        database.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil, projectRoot: projectRoot, source: "audit",
            toolName: toolId, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.secret.allow",
            command: ArtifactAuditPayloads.secretAllow(
                artifactId: artifactId, sourcePane: sourcePane,
                hitCount: hitCount, hitPatternNames: hitPatternNames,
                toolId: toolId
            ),
            modelTier: nil
        )
    }

    public func recordVersions(
        artifactId: String, sourcePane: String, count: Int,
        toolId: String?, sessionId: String?, projectRoot: String?
    ) {
        database.recordTokenEvent(
            sessionId: sessionId ?? "anonymous",
            paneId: nil, projectRoot: projectRoot, source: "audit",
            toolName: toolId, model: nil,
            inputTokens: 0, outputTokens: 0, savedTokens: 0, costCents: 0,
            feature: "artifact.versions",
            command: ArtifactAuditPayloads.versions(
                artifactId: artifactId, sourcePane: sourcePane,
                count: count, toolId: toolId
            ),
            modelTier: nil
        )
    }
}

// MARK: - Payloads (JSON, sorted keys, no content)

public enum ArtifactAuditPayloads {

    public static func read(
        artifactId: String,
        sourcePane: String,
        allowedSecrets: Bool,
        toolId: String?
    ) -> String {
        var dict: [String: Any] = [
            "artifact_id": artifactId,
            "source_pane": sourcePane,
            "allowed_secrets": allowedSecrets,
        ]
        if let toolId { dict["tool_id"] = toolId }
        return encode(dict)
    }

    public static func secretAllow(
        artifactId: String,
        sourcePane: String,
        hitCount: Int,
        hitPatternNames: [String],
        toolId: String?
    ) -> String {
        var dict: [String: Any] = [
            "artifact_id": artifactId,
            "source_pane": sourcePane,
            "hit_count": hitCount,
            "hit_pattern_names": hitPatternNames,
        ]
        if let toolId { dict["tool_id"] = toolId }
        return encode(dict)
    }

    public static func versions(
        artifactId: String,
        sourcePane: String,
        count: Int,
        toolId: String?
    ) -> String {
        var dict: [String: Any] = [
            "artifact_id": artifactId,
            "source_pane": sourcePane,
            "count": count,
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
