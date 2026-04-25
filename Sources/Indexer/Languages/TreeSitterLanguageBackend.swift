import Foundation
import SwiftTreeSitter

/// Per-language tree-sitter symbol-extraction backend.
///
/// One backend per grammar (or per closely-related grammar family —
/// e.g. one TypeScriptBackend handles ts/tsx/js because their node
/// types and extraction logic are uniform). Each backend owns the
/// AST walk for its language(s); `TreeSitterBackend` becomes a thin
/// dispatcher that picks a backend by language id and forwards the
/// parsed tree to it.
///
/// ## Adding a new language
///
/// 1. Add the grammar binary product to `Package.swift` under
///    `targets:` and to the `Indexer` target's `dependencies:`.
/// 2. Add the language id to `TreeSitterBackend.supportedLanguages`
///    and the `language(for:)` switch.
/// 3. Create `Sources/Indexer/Languages/<Lang>Backend.swift`
///    conforming to this protocol. Use `TreeSitterBackend`'s shared
///    helpers (`nodeText`, `nodeName`, `findChildByType`, `findBody`,
///    `extractFunction`, `extractTSDeclaration`, …) — they are
///    `internal` and live next door in `Helpers.swift`.
/// 4. Register the backend in `TreeSitterBackend.backend(for:)`.
/// 5. Add a test file under `Tests/SenkaniTests/` covering the
///    language's symbol extraction.
///
/// See `TomlBackend.swift` and `GraphQLBackend.swift` for the
/// minimal worked examples (TOML uses table/pair recursion;
/// GraphQL uses a flat top-level scan with a node-type → SymbolKind
/// map).
///
/// ## Contract
///
/// - `supports(_:)` decides whether this backend handles a given
///   language id. The dispatcher walks all registered backends and
///   picks the first that claims the language.
/// - `extractSymbols(...)` walks the AST root and appends entries to
///   the inout array. The signature mirrors the legacy `walkNode`
///   so the dispatcher can swap backends in / out without touching
///   `IncrementalParser`.
/// - Backends MUST preserve container recursion: when descending
///   into a body (class body, namespace body, impl block, TOML
///   table), the recursive call MUST set `container:` to the
///   enclosing symbol's name (or pass it through unchanged for
///   transparent wrappers).
/// - Backends own their own internal recursion — they do not call
///   back into the central `walkNode`. (If a backend wants to share
///   walk logic with another backend, factor it into a helper, not
///   a callback.)
internal protocol TreeSitterLanguageBackend {
    /// Returns true if this backend handles the given language id.
    static func supports(_ language: String) -> Bool

    /// Walk the AST root and append index entries.
    ///
    /// - Parameters:
    ///   - root: parsed tree root node.
    ///   - file: project-relative source path (used as the `file`
    ///     field on emitted `IndexEntry`s).
    ///   - source: the file content, NSString-cast for byte-range
    ///     extraction by node helpers.
    ///   - lines: the file content split on `\n`, 0-indexed.
    ///   - container: enclosing symbol name (nil for top-level).
    ///   - entries: the accumulator — backends append, never reset.
    static func extractSymbols(
        from root: Node,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    )
}
