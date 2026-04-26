import Foundation
import SwiftTreeSitter

/// CSS symbol-extraction backend.
///
/// CSS has no first-class symbol surface in senkani's model — rule
/// selectors are not stable identifiers and there are no functions
/// or named declarations to extract. The backend exists to satisfy
/// the dispatcher's "every supported language has a backend"
/// invariant after the 10f migration.
///
/// Tests in `TreeSitterHtmlCssTests.swift` only verify grammar
/// loading and FileWalker mapping; this backend's `extractSymbols`
/// returning zero entries matches the previous dispatcher behavior
/// (CSS used to fall through to walkNode's default recurse, which
/// also emitted nothing).
internal enum CssBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "css"
    }

    static func extractSymbols(
        from root: Node,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        // Intentionally empty — CSS emits no symbols today.
    }
}
