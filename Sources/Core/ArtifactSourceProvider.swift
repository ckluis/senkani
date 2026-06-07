import Foundation

/// V.9a — Provider seam for `ArtifactStore`. One implementation per
/// source-pane (PaneDiary, SprintReview, Filesystem). Providers are
/// pure-read: they walk their underlying surface and project records
/// onto the unified API. Body bytes come back from `read(_:)`; never
/// from `list()` so the secret gate is enforceable.
///
/// Spec: spec/artifact_gallery.md.
public protocol ArtifactSourceProvider: Sendable {
    var sourcePane: ArtifactSourcePane { get }
    func list() -> [ArtifactRecord]
    func read(_ id: ArtifactID) throws -> ArtifactBody
    func versions(of id: ArtifactID) -> [ArtifactRecord]
}
