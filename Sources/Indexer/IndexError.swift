import Foundation

/// Typed failure for the public Indexer surface.
///
/// Before 2026-04-26 the public API of `CTagsBackend.index`,
/// `TreeSitterBackend.index` / `extractSymbols`, `RegexBackend.index`,
/// `IndexEngine.indexFileIncremental`, and
/// `DependencyExtractor.extractImports` / `extractAllImports`
/// returned `[]` on every failure mode — binary missing, parse failure,
/// unsupported language, file unreadable. Callers could not tell
/// "no symbols here" from "the tool you depend on is broken."
///
/// This enum makes those failures explicit. The four cases cover the
/// only things that can actually go wrong in the leaf indexers; if a
/// new failure mode shows up later, add a case here rather than silently
/// returning empty.
public enum IndexError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A required external binary (e.g. `ctags`) is not installed
    /// or not on the discovered path. The associated value is the
    /// short tool name (`"ctags"`), not a full path.
    case binaryMissing(String)

    /// A parser, tree-sitter language setup, or batch process failed.
    /// `file` is the project-relative path the caller passed in (or a
    /// sentinel like `"<ctags batch>"` for batch-level failures);
    /// `reason` is a short human-readable hint (no absolute paths).
    case parseFailed(file: String, reason: String)

    /// The language identifier is not supported by the backend the
    /// caller invoked. Use this for "we don't know that language at
    /// all" — not for "we know the language but the file is empty."
    case unsupportedLanguage(String)

    /// File system I/O failed (file missing, unreadable, encoding
    /// error). `file` is the path the caller provided; `underlying`
    /// is a short reason string.
    case ioError(file: String, underlying: String)

    public var description: String {
        switch self {
        case .binaryMissing(let tool):
            return "IndexError.binaryMissing(\(tool))"
        case .parseFailed(let file, let reason):
            return "IndexError.parseFailed(\(file): \(reason))"
        case .unsupportedLanguage(let lang):
            return "IndexError.unsupportedLanguage(\(lang))"
        case .ioError(let file, let underlying):
            return "IndexError.ioError(\(file): \(underlying))"
        }
    }
}
