import Foundation
import CryptoKit
import SwiftTreeSitter

/// Thread-safe cache of parsed tree-sitter trees keyed by file path.
/// Stores the tree, source content (for edit diffing), content hash, and language.
public final class TreeCache: @unchecked Sendable {

    struct Entry {
        let tree: MutableTree
        let content: String
        let contentHash: String
        let language: String
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    public init() {}

    /// Store a parsed tree for a file.
    public func store(file: String, tree: MutableTree, content: String, contentHash: String, language: String) {
        lock.lock()
        defer { lock.unlock() }
        cache[file] = Entry(tree: tree, content: content, contentHash: contentHash, language: language)
    }

    /// Look up a cached tree by relative file path.
    public func lookup(file: String) -> (tree: MutableTree, content: String, contentHash: String, language: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[file] else { return nil }
        return (entry.tree, entry.content, entry.contentHash, entry.language)
    }

    /// Remove a cached tree.
    public func remove(file: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.removeValue(forKey: file)
    }

    /// Number of cached trees.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// Remove all cached trees.
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache.removeAll()
    }

    /// SHA-256 hash of a string's UTF-8 representation.
    public static func hash(_ content: String) -> String {
        let data = Data(content.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
