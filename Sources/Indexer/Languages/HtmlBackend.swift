import Foundation
import SwiftTreeSitter

/// HTML symbol-extraction backend.
///
/// HTML has no first-class symbol surface in senkani's model — there
/// are no functions, classes, or named declarations to extract. The
/// backend exists to satisfy the dispatcher's "every supported
/// language has a backend" invariant after the 10f migration.
///
/// Tests in `TreeSitterHtmlCssTests.swift` only verify grammar
/// loading and FileWalker mapping; this backend's `extractSymbols`
/// returning zero entries matches the previous dispatcher behavior
/// (HTML used to fall through to walkNode's default recurse, which
/// also emitted nothing).
internal enum HtmlBackend: TreeSitterLanguageBackend {

    static func supports(_ language: String) -> Bool {
        language == "html"
    }

    static func extractSymbols(
        from root: Node,
        file: String,
        source: NSString,
        lines: [String],
        container: String?,
        entries: inout [IndexEntry]
    ) {
        // Intentionally empty — HTML emits no symbols today.
    }
}
