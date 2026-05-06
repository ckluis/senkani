import Foundation

/// Envelope describing a SkillPack on disk. See `spec/skill_packs.md`
/// for the canonical schema. V.11a ships schema_version 1 only.
public struct PackManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let name: String
    public let description: String
    public let version: String
    public let author: String
    public let senkaniMinVersion: String
    public let skills: [String]
    public let policy: String?
    public let context: String?
    public let provenance: Provenance

    public struct Provenance: Codable, Sendable, Equatable {
        public let sourceUrl: String?
        public let sha256: String?
        public let signedBy: String?

        public init(sourceUrl: String? = nil, sha256: String? = nil, signedBy: String? = nil) {
            self.sourceUrl = sourceUrl
            self.sha256 = sha256
            self.signedBy = signedBy
        }

        enum CodingKeys: String, CodingKey {
            case sourceUrl = "source_url"
            case sha256
            case signedBy = "signed_by"
        }
    }

    public init(
        schemaVersion: Int = 1,
        name: String,
        description: String,
        version: String,
        author: String,
        senkaniMinVersion: String,
        skills: [String],
        policy: String? = nil,
        context: String? = nil,
        provenance: Provenance = Provenance()
    ) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.description = description
        self.version = version
        self.author = author
        self.senkaniMinVersion = senkaniMinVersion
        self.skills = skills
        self.policy = policy
        self.context = context
        self.provenance = provenance
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case name, description, version, author
        case senkaniMinVersion = "senkani_min_version"
        case skills, policy, context, provenance
    }
}

/// Thin wrapper over JSONDecoder so callers don't have to know the
/// snake_case mapping lives in the type itself. Returns a structured
/// error path on failure.
public enum PackManifestParser {
    public enum ParseError: Error, Equatable, Sendable {
        case readFailed(path: String, detail: String)
        case decodeFailed(detail: String)
        case unsupportedSchemaVersion(Int)
        case nameInvalid(String)
        case versionInvalid(String)
        case skillsEmpty
    }

    public static func load(from url: URL) throws -> PackManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.readFailed(path: url.path, detail: "\(error)")
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> PackManifest {
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: data)
        } catch {
            throw ParseError.decodeFailed(detail: "\(error)")
        }
        try validate(manifest)
        return manifest
    }

    public static func validate(_ manifest: PackManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw ParseError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard isKebabCase(manifest.name) else {
            throw ParseError.nameInvalid(manifest.name)
        }
        guard isSemverish(manifest.version) else {
            throw ParseError.versionInvalid(manifest.version)
        }
        guard !manifest.skills.isEmpty else {
            throw ParseError.skillsEmpty
        }
    }

    private static func isKebabCase(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        guard s.allSatisfy({ allowed.contains($0) }) else { return false }
        guard s.first != "-", s.last != "-" else { return false }
        return !s.contains("--")
    }

    private static func isSemverish(_ s: String) -> Bool {
        let parts = s.split(separator: ".")
        guard parts.count == 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isNumber }
        }
    }
}

/// HookRouter policy fragment shape. V.11a stores fragments on disk
/// only — the live HookRouter merge ships in V.11b. Even so, the
/// fragment is parsed at install time so collision-diff can detect a
/// scope_key clash without a second read.
public struct HookRouterFragment: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let scopeKey: String
    public let rules: [Rule]

    public struct Rule: Codable, Sendable, Equatable {
        public let kind: String
        public let match: String
        public let reason: String?
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case scopeKey = "scope_key"
        case rules
    }
}

public enum HookRouterFragmentParser {
    public enum ParseError: Error, Equatable, Sendable {
        case readFailed(path: String, detail: String)
        case decodeFailed(detail: String)
        case unsupportedSchemaVersion(Int)
        case scopeKeyEmpty
    }

    public static func load(from url: URL) throws -> HookRouterFragment {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ParseError.readFailed(path: url.path, detail: "\(error)")
        }
        return try parse(data: data)
    }

    public static func parse(data: Data) throws -> HookRouterFragment {
        let fragment: HookRouterFragment
        do {
            fragment = try JSONDecoder().decode(HookRouterFragment.self, from: data)
        } catch {
            throw ParseError.decodeFailed(detail: "\(error)")
        }
        guard fragment.schemaVersion == 1 else {
            throw ParseError.unsupportedSchemaVersion(fragment.schemaVersion)
        }
        guard !fragment.scopeKey.isEmpty else {
            throw ParseError.scopeKeyEmpty
        }
        return fragment
    }
}
