import Foundation

// MARK: - BundleDocument
//
// The JSON schema for `senkani bundle --format json` and
// `senkani_bundle format:"json"`. Field names are a STABLE CONTRACT —
// once shipped, renaming a key is a breaking change for any consumer
// that decodes this shape. Add new fields as optionals; do not rename
// or repurpose existing ones.
//
// Same content as the markdown variant, in canonical ordering:
// header → stats → outlines → deps → kb → readme. Sections omitted
// by `include` or dropped for budget are represented as `nil`.
// A populated `truncated` block records which section triggered the
// cut (budget was exceeded while composing it).

public struct BundleDocument: Codable, Sendable, Equatable {
    public var header: Header
    public var stats: Stats
    public var outlines: Outlines?
    public var deps: Deps?
    public var kb: KnowledgeBase?
    public var readme: Readme?
    public var truncated: Truncation?

    public struct Header: Codable, Sendable, Equatable {
        public var projectName: String
        public var generated: String        // ISO8601 w/ internet datetime
        public var indexUpdated: String     // ISO8601 of SymbolIndex.generated
        public var maxTokens: Int
        public var charBudget: Int
        public var provenance: String       // BundleComposer.provenanceMarker
    }

    public struct Stats: Codable, Sendable, Equatable {
        public var filesIndexed: Int
        public var symbols: Int
        public var importEdges: Int
        public var kbEntities: Int
    }

    public struct Outlines: Codable, Sendable, Equatable {
        public var files: [FileOutline]
    }

    public struct FileOutline: Codable, Sendable, Equatable {
        public var path: String
        public var symbols: [SymbolOutline]
    }

    public struct SymbolOutline: Codable, Sendable, Equatable {
        public var name: String
        public var kind: String             // SymbolKind.rawValue
        public var line: Int
        public var members: [SymbolOutline]
    }

    public struct Deps: Codable, Sendable, Equatable {
        public var topImportedBy: [DepEntry]
    }

    public struct DepEntry: Codable, Sendable, Equatable {
        public var module: String
        public var importedByCount: Int
    }

    public struct KnowledgeBase: Codable, Sendable, Equatable {
        public var entities: [Entity]
    }

    public struct Entity: Codable, Sendable, Equatable {
        public var name: String
        public var type: String
        public var file: String?
        public var mentions: Int
        public var understanding: String?   // SecretDetector-redacted
        public var understandingTruncated: Bool
    }

    public struct Readme: Codable, Sendable, Equatable {
        public var content: String          // SecretDetector-redacted
        public var truncated: Bool
    }

    public struct Truncation: Codable, Sendable, Equatable {
        public var section: String          // BundleSection.rawValue
        public var reason: String
    }
}
