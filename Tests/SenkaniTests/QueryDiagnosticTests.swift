import Foundation
import Testing
import SwiftTreeSitter
@testable import Indexer

@Suite("Query Diagnostic — find failing lines")
struct QueryDiagnosticTests {

    @Test("Verify fixed queries compile fully")
    func verifyFixedQueries() {
        let fixed: [(String, String)] = [
            ("cpp", """
            (comment) @comment
            (string_literal) @string
            (raw_string_literal) @string
            (system_lib_string) @string
            (char_literal) @string
            (number_literal) @number
            (true) @constant
            (false) @constant
            (null) @constant
            (type_identifier) @type
            (namespace_identifier) @module
            (identifier) @variable
            (field_identifier) @property
            """),
            ("csharp", """
            (comment) @comment
            (string_literal) @string
            (verbatim_string_literal) @string
            (interpolated_string_expression) @string
            (character_literal) @string
            (integer_literal) @number
            (real_literal) @number
            (boolean_literal) @constant
            (null_literal) @constant
            (predefined_type) @type
            (identifier) @variable
            """),
            ("kotlin", """
            (line_comment) @comment
            (multiline_comment) @comment
            (string_literal) @string
            (integer_literal) @number
            (real_literal) @number
            (boolean_literal) @constant
            (type_identifier) @type
            (simple_identifier) @variable
            """),
            ("haskell", """
            (comment) @comment
            (string) @string
            (char) @string
            (integer) @number
            (float) @number
            (variable) @variable
            (constructor) @type
            """),
            ("zig", """
            (comment) @comment
            (string) @string
            (integer) @number
            (float) @number
            (identifier) @variable
            """),
        ]

        for (lang, queryStr) in fixed {
            guard let tsLang = TreeSitterBackend.language(for: lang) else {
                print("SKIP [\(lang)]")
                continue
            }
            if let data = queryStr.data(using: .utf8), let _ = try? Query(language: tsLang, data: data) {
                let lines = queryStr.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                print("PASS [\(lang)]: \(lines.count)/\(lines.count) lines compile")
            } else {
                print("FAIL [\(lang)]: full query does not compile")
            }
        }
    }
}
