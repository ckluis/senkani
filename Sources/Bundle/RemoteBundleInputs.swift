import Foundation

// MARK: - RemoteBundleInputs
//
// The remote analog of `BundleInputs`. A remote snapshot has no symbol
// index and no dep graph — GitHub's tree API gives us a file listing
// only. The composer treats symbols/deps/kb as empty and renders the
// file list as the outlines section.
//
// Secrets: `readme` is already `SecretDetector`-redacted by the client
// before it reaches this struct (see `RemoteRepoClient.sanitize`).
// `files` is path-only, no body content, so no additional scan needed.

public struct RemoteBundleInputs: Sendable {
    /// Canonical `owner/name` identifier — validated before fetch.
    public let repo: String
    /// Git ref the snapshot was taken from (nil == HEAD).
    public let ref: String?
    /// Relative file paths, sorted lex-ascending for determinism.
    public let files: [String]
    /// Already-sanitized README text, or nil when none was found.
    public let readme: String?
    /// When the snapshot was generated (injectable for tests).
    public let generated: Date
    /// True iff GitHub flagged the tree response as truncated. Surfaces
    /// in the bundle header so callers know the listing is partial.
    public let treeTruncated: Bool

    public init(
        repo: String,
        ref: String? = nil,
        files: [String],
        readme: String? = nil,
        generated: Date = Date(),
        treeTruncated: Bool = false
    ) {
        self.repo = repo
        self.ref = ref
        self.files = files.sorted()
        self.readme = readme
        self.generated = generated
        self.treeTruncated = treeTruncated
    }
}
