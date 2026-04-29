import Foundation

/// W.6 — Diátaxis docs-shape lint.
///
/// Enforces the project convention from `spec/spec.md` →
/// "Documentation Standard": every named Phase T/U/V/W component
/// must ship docs in all four Diátaxis shapes — `tutorial` (set-up
/// steps), `howTo` (configuration recipes), `reference` (schemas +
/// APIs), `explanation` (why it exists). No collapsing across
/// quadrants.
///
/// The lint is *structural only*: it asserts each declared doc
/// path resolves to a non-empty file. Length / quality / freshness
/// gates are deliberately out of scope (see `spec/spec.md` for the
/// rationale — keeping v1 binary keeps the gate fast and the
/// failures unambiguous).
public enum DocsShape: String, CaseIterable, Sendable, Codable {
    case tutorial
    case howTo
    case reference
    case explanation
}

/// Per-component docs manifest. Each entry declares the four
/// Diátaxis shapes a component ships. Missing keys map to `nil`,
/// which the linter reports as `missing`.
public struct ComponentDocs: Equatable, Sendable, Codable {
    public let id: String
    public let paths: [DocsShape: String]

    public init(id: String, paths: [DocsShape: String]) {
        self.id = id
        self.paths = paths
    }
}

public struct DocsShapeIssue: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case missingDeclaration
        case fileNotFound
        case fileEmpty
    }

    public let componentID: String
    public let shape: DocsShape
    public let kind: Kind
    public let path: String?

    public var message: String {
        switch kind {
        case .missingDeclaration:
            return "[\(componentID)] missing \(shape.rawValue) doc declaration"
        case .fileNotFound:
            return "[\(componentID)] \(shape.rawValue) doc not found at \(path ?? "<nil>")"
        case .fileEmpty:
            return "[\(componentID)] \(shape.rawValue) doc is empty at \(path ?? "<nil>")"
        }
    }
}

/// Read-only file probe the linter depends on. Real callers pass
/// `FileSystemProbe.real`; tests pass an in-memory map.
public struct FileSystemProbe: Sendable {
    public let exists: @Sendable (_ path: String) -> Bool
    public let isNonEmpty: @Sendable (_ path: String) -> Bool

    public init(
        exists: @escaping @Sendable (_ path: String) -> Bool,
        isNonEmpty: @escaping @Sendable (_ path: String) -> Bool
    ) {
        self.exists = exists
        self.isNonEmpty = isNonEmpty
    }

    public static let real = FileSystemProbe(
        exists: { FileManager.default.fileExists(atPath: $0) },
        isNonEmpty: { path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            return size > 0
        }
    )

    public static func inMemory(files: [String: String]) -> FileSystemProbe {
        FileSystemProbe(
            exists: { files[$0] != nil },
            isNonEmpty: { (files[$0] ?? "").isEmpty == false }
        )
    }
}

public enum DocsShapeLinter {
    /// Lint a list of components against the file system probe.
    ///
    /// Returns issues in deterministic order: components in the
    /// order supplied, shapes in `DocsShape.allCases` order. An
    /// empty result means every component declares all four shapes
    /// and every declared file exists with non-zero length.
    public static func lint(
        components: [ComponentDocs],
        fileSystem: FileSystemProbe = .real
    ) -> [DocsShapeIssue] {
        var issues: [DocsShapeIssue] = []
        for component in components {
            for shape in DocsShape.allCases {
                guard let path = component.paths[shape] else {
                    issues.append(.init(
                        componentID: component.id,
                        shape: shape,
                        kind: .missingDeclaration,
                        path: nil
                    ))
                    continue
                }
                if fileSystem.exists(path) == false {
                    issues.append(.init(
                        componentID: component.id,
                        shape: shape,
                        kind: .fileNotFound,
                        path: path
                    ))
                    continue
                }
                if fileSystem.isNonEmpty(path) == false {
                    issues.append(.init(
                        componentID: component.id,
                        shape: shape,
                        kind: .fileEmpty,
                        path: path
                    ))
                }
            }
        }
        return issues
    }
}
