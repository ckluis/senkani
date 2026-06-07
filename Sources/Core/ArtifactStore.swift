import Foundation

// MARK: - V.9a — ArtifactStore Core API
//
// Unified read surface over the three artifact-bearing producers in
// senkani: pane diaries, sprint-review snapshots, and the on-disk
// artifact directory at `~/.senkani/artifacts/`. The store is the
// reader; producers continue to write into their own surfaces.
//
// Spec: spec/artifact_gallery.md. UX layout (V.9b) is out of scope
// for V.9a. CLI/MCP surfaces are also out of scope (V.9b or V.9c).
//
// Privacy contract (Cavoukian P0):
//   - `list(filter:)` returns metadata only — never body bytes — so
//     the secret gate cannot be bypassed by listing.
//   - `read(_:allowSecrets:)` runs SecretDetector.scan on the body
//     before returning. On hit + allowSecrets=false the call throws
//     ArtifactReadError.secretsBlocked carrying lane + hit count
//     only (never offending content).
//   - On allowSecrets=true override, a chained `artifact.secret.allow`
//     row fires through ArtifactAuditRecorder (T.5 chain).
//   - ArtifactRedactionMarker carries SecretDetector pattern names
//     + hit count only — never offending content.

// MARK: - ID

public struct ArtifactID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public init(sourcePane: ArtifactSourcePane, surfaceKey: String, rowOrPath: String) {
        self.raw = "\(sourcePane.rawValue):\(surfaceKey):\(rowOrPath)"
    }

    public var description: String { raw }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.raw = try c.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
}

// MARK: - Source pane

public enum ArtifactSourcePane: String, Codable, CaseIterable, Sendable {
    case paneDiary
    case sprintReview
    case filesystem
}

// MARK: - Record

public struct ArtifactRecord: Codable, Sendable, Equatable {
    public let id: ArtifactID
    public let sourcePane: ArtifactSourcePane
    public let tags: Set<String>
    public let version: Int
    public let createdAt: Date
    public let previousVersion: ArtifactID?
    public let redactionMarker: ArtifactRedactionMarker?

    public init(
        id: ArtifactID,
        sourcePane: ArtifactSourcePane,
        tags: Set<String>,
        version: Int,
        createdAt: Date,
        previousVersion: ArtifactID? = nil,
        redactionMarker: ArtifactRedactionMarker? = nil
    ) {
        self.id = id
        self.sourcePane = sourcePane
        self.tags = tags
        self.version = version
        self.createdAt = createdAt
        self.previousVersion = previousVersion
        self.redactionMarker = redactionMarker
    }

    // Custom Codable to keep JSON byte-stable across round-trips.
    // Set<String> iteration order is non-deterministic, so the tags
    // field is encoded as a sorted array.
    private enum CodingKeys: String, CodingKey {
        case id, sourcePane, tags, version, createdAt
        case previousVersion, redactionMarker
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(ArtifactID.self, forKey: .id)
        self.sourcePane = try c.decode(ArtifactSourcePane.self, forKey: .sourcePane)
        let arr = try c.decode([String].self, forKey: .tags)
        self.tags = Set(arr)
        self.version = try c.decode(Int.self, forKey: .version)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.previousVersion = try c.decodeIfPresent(ArtifactID.self, forKey: .previousVersion)
        self.redactionMarker = try c.decodeIfPresent(ArtifactRedactionMarker.self, forKey: .redactionMarker)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sourcePane, forKey: .sourcePane)
        try c.encode(tags.sorted(), forKey: .tags)
        try c.encode(version, forKey: .version)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(previousVersion, forKey: .previousVersion)
        try c.encodeIfPresent(redactionMarker, forKey: .redactionMarker)
    }
}

// MARK: - Redaction marker

public struct ArtifactRedactionMarker: Codable, Sendable, Equatable {
    public let sourcePane: ArtifactSourcePane
    public let hitPatternNames: [String]
    public let hitCount: Int

    public init(sourcePane: ArtifactSourcePane, hitPatternNames: [String], hitCount: Int) {
        self.sourcePane = sourcePane
        self.hitPatternNames = hitPatternNames
        self.hitCount = hitCount
    }
}

// MARK: - Filter

public struct ArtifactFilter: Sendable, Equatable {
    public var tags: Set<String>?
    public var sourcePane: Set<ArtifactSourcePane>?
    public var versionRange: ClosedRange<Int>?
    public var since: Date?

    public init(
        tags: Set<String>? = nil,
        sourcePane: Set<ArtifactSourcePane>? = nil,
        versionRange: ClosedRange<Int>? = nil,
        since: Date? = nil
    ) {
        self.tags = tags
        self.sourcePane = sourcePane
        self.versionRange = versionRange
        self.since = since
    }

    public static let unconstrained = ArtifactFilter()

    public func matches(_ record: ArtifactRecord) -> Bool {
        if let want = tags, !want.isEmpty {
            // OR within the set: any overlap counts.
            if record.tags.intersection(want).isEmpty { return false }
        }
        if let panes = sourcePane, !panes.isEmpty {
            if !panes.contains(record.sourcePane) { return false }
        }
        if let range = versionRange {
            if !range.contains(record.version) { return false }
        }
        if let since {
            if record.createdAt < since { return false }
        }
        return true
    }
}

// MARK: - Body

public struct ArtifactBody: Sendable, Equatable {
    public let bytes: Data
    public init(bytes: Data) { self.bytes = bytes }
    public init(_ utf8: String) { self.bytes = Data(utf8.utf8) }
    public var utf8: String? { String(data: bytes, encoding: .utf8) }
}

// MARK: - Error

public enum ArtifactReadError: Error, Equatable, Sendable {
    /// Secret detected; allowSecrets is false. Carries lane + hit
    /// count only — never offending content (Schneier P0).
    case secretsBlocked(lane: ArtifactSourcePane, hitCount: Int)
    case notFound(id: ArtifactID)
    case ioFailure(String)
}

// MARK: - Store

public struct ArtifactStore: Sendable {
    public let providers: [any ArtifactSourceProvider]
    public let recorder: (any ArtifactAuditRecorder)?

    public init(providers: [any ArtifactSourceProvider], recorder: (any ArtifactAuditRecorder)? = nil) {
        self.providers = providers
        self.recorder = recorder
    }

    /// List artifacts across all providers matching the filter.
    /// Returns lane-then-creation-order (provider-array order then
    /// per-provider list-output order — providers sort their own
    /// outputs). No body bytes are returned.
    public func list(filter: ArtifactFilter = .unconstrained) -> [ArtifactRecord] {
        var out: [ArtifactRecord] = []
        for provider in providers {
            if let panes = filter.sourcePane, !panes.isEmpty,
               !panes.contains(provider.sourcePane) {
                continue
            }
            for record in provider.list() where filter.matches(record) {
                out.append(record)
            }
        }
        return out
    }

    /// Fetch the body for an artifact. Runs SecretDetector.scan; on
    /// hit + allowSecrets=false throws `secretsBlocked`. On override
    /// fires a chained `artifact.secret.allow` row. Every successful
    /// read fires a chained `artifact.read` row.
    public func read(
        _ id: ArtifactID,
        allowSecrets: Bool = false,
        toolId: String? = nil,
        sessionId: String? = nil,
        projectRoot: String? = nil
    ) throws -> ArtifactBody {
        guard let provider = providerFor(id) else {
            throw ArtifactReadError.notFound(id: id)
        }

        let body = try provider.read(id)
        let scan: SecretDetector.ScanResult? = body.utf8.map { SecretDetector.scan($0) }
        let hitCount = scan?.patterns.count ?? 0
        let hitPatterns = scan?.patterns ?? []

        if hitCount > 0 && !allowSecrets {
            throw ArtifactReadError.secretsBlocked(
                lane: provider.sourcePane, hitCount: hitCount)
        }

        if hitCount > 0 && allowSecrets {
            recorder?.recordSecretAllow(
                artifactId: id.raw,
                sourcePane: provider.sourcePane.rawValue,
                hitCount: hitCount,
                hitPatternNames: hitPatterns,
                toolId: toolId,
                sessionId: sessionId,
                projectRoot: projectRoot
            )
        }

        recorder?.recordRead(
            artifactId: id.raw,
            sourcePane: provider.sourcePane.rawValue,
            allowedSecrets: allowSecrets,
            toolId: toolId,
            sessionId: sessionId,
            projectRoot: projectRoot
        )

        return body
    }

    /// Return the lineage chain (oldest → newest) for the artifact.
    /// Empty array if no lineage (PaneDiary + SprintReview providers
    /// return empty for V.9a — lineage recording follow-up filed).
    public func versions(
        of id: ArtifactID,
        toolId: String? = nil,
        sessionId: String? = nil,
        projectRoot: String? = nil
    ) -> [ArtifactRecord] {
        guard let provider = providerFor(id) else { return [] }
        let chain = provider.versions(of: id)
        recorder?.recordVersions(
            artifactId: id.raw,
            sourcePane: provider.sourcePane.rawValue,
            count: chain.count,
            toolId: toolId,
            sessionId: sessionId,
            projectRoot: projectRoot
        )
        return chain
    }

    private func providerFor(_ id: ArtifactID) -> (any ArtifactSourceProvider)? {
        let prefix = id.raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let pane = ArtifactSourcePane(rawValue: prefix) else { return nil }
        return providers.first(where: { $0.sourcePane == pane })
    }
}
