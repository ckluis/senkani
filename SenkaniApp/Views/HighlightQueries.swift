import Foundation

/// Syntax highlight queries for the Code Editor pane.
/// Each query uses ONLY leaf node types proven to exist in the vendored grammars.
/// No predicates, no string literal matches, no field names.
/// Safe to compile against any grammar version.
enum HighlightQueries {

    static func query(for language: String) -> String? {
        switch language {
        case "swift":      return swift
        case "python":     return python
        case "typescript": return typescript
        case "tsx":        return tsx
        case "javascript": return javascript
        case "go":         return goLang
        case "rust":       return rust
        case "java":       return java
        case "c":          return c
        case "cpp":        return cpp
        case "csharp":     return csharp
        case "ruby":       return ruby
        case "php":        return php
        case "kotlin":     return kotlin
        case "bash":       return bash
        case "lua":        return lua
        case "scala":      return scala
        case "elixir":     return elixir
        case "haskell":    return haskell
        case "zig":        return zig
        case "html":       return html
        case "css":        return css
        default:           return nil
        }
    }

    // MARK: - Swift
    static let swift = """
    (comment) @comment
    (multiline_comment) @comment
    (line_string_literal) @string
    (multi_line_string_literal) @string
    (raw_string_literal) @string
    (integer_literal) @number
    (real_literal) @number
    (boolean_literal) @constant
    (type_identifier) @type
    (simple_identifier) @variable
    """

    // MARK: - Python
    static let python = """
    (comment) @comment
    (string) @string
    (integer) @number
    (float) @number
    (true) @constant
    (false) @constant
    (none) @constant
    (type) @type
    (identifier) @variable
    """

    // MARK: - TypeScript
    static let typescript = """
    (comment) @comment
    (string) @string
    (template_string) @string
    (number) @number
    (true) @constant
    (false) @constant
    (null) @constant
    (undefined) @constant
    (type_identifier) @type
    (identifier) @variable
    (property_identifier) @property
    """

    // MARK: - TSX (same as TypeScript)
    static let tsx = typescript

    // MARK: - JavaScript
    static let javascript = """
    (comment) @comment
    (string) @string
    (template_string) @string
    (number) @number
    (true) @constant
    (false) @constant
    (null) @constant
    (undefined) @constant
    (identifier) @variable
    (property_identifier) @property
    """

    // MARK: - Go
    static let goLang = """
    (comment) @comment
    (raw_string_literal) @string
    (interpreted_string_literal) @string
    (rune_literal) @string
    (int_literal) @number
    (float_literal) @number
    (true) @constant
    (false) @constant
    (nil) @constant
    (type_identifier) @type
    (package_identifier) @module
    (identifier) @variable
    (field_identifier) @property
    """

    // MARK: - Rust
    static let rust = """
    (line_comment) @comment
    (block_comment) @comment
    (string_literal) @string
    (raw_string_literal) @string
    (char_literal) @string
    (integer_literal) @number
    (float_literal) @number
    (boolean_literal) @constant
    (type_identifier) @type
    (identifier) @variable
    (field_identifier) @property
    """

    // MARK: - Java
    static let java = """
    (line_comment) @comment
    (block_comment) @comment
    (string_literal) @string
    (character_literal) @string
    (decimal_integer_literal) @number
    (hex_integer_literal) @number
    (octal_integer_literal) @number
    (decimal_floating_point_literal) @number
    (true) @constant
    (false) @constant
    (null_literal) @constant
    (type_identifier) @type
    (identifier) @variable
    """

    // MARK: - C
    static let c = """
    (comment) @comment
    (string_literal) @string
    (system_lib_string) @string
    (char_literal) @string
    (number_literal) @number
    (true) @constant
    (false) @constant
    (null) @constant
    (type_identifier) @type
    (identifier) @variable
    (field_identifier) @property
    """

    // MARK: - C++
    static let cpp = """
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
    """

    // MARK: - C#
    static let csharp = """
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
    """

    // MARK: - Ruby
    static let ruby = """
    (comment) @comment
    (string) @string
    (heredoc_body) @string
    (integer) @number
    (float) @number
    (true) @constant
    (false) @constant
    (nil) @constant
    (constant) @type
    (identifier) @variable
    """

    // MARK: - PHP
    static let php = """
    (comment) @comment
    (string) @string
    (encapsed_string) @string
    (heredoc) @string
    (integer) @number
    (float) @number
    (boolean) @constant
    (null) @constant
    (name) @variable
    (variable_name) @variable
    """

    // MARK: - Kotlin
    static let kotlin = """
    (line_comment) @comment
    (multiline_comment) @comment
    (string_literal) @string
    (integer_literal) @number
    (real_literal) @number
    (boolean_literal) @constant
    (type_identifier) @type
    (simple_identifier) @variable
    """

    // MARK: - Bash
    static let bash = """
    (comment) @comment
    (string) @string
    (raw_string) @string
    (number) @number
    (word) @variable
    (variable_name) @variable
    (command_name) @function
    """

    // MARK: - Lua
    static let lua = """
    (comment) @comment
    (string) @string
    (number) @number
    (true) @constant
    (false) @constant
    (nil) @constant
    (identifier) @variable
    """

    // MARK: - Scala
    static let scala = """
    (comment) @comment
    (block_comment) @comment
    (string) @string
    (integer_literal) @number
    (floating_point_literal) @number
    (boolean_literal) @constant
    (null_literal) @constant
    (type_identifier) @type
    (identifier) @variable
    """

    // MARK: - Elixir
    static let elixir = """
    (comment) @comment
    (string) @string
    (charlist) @string
    (integer) @number
    (float) @number
    (boolean) @constant
    (nil) @constant
    (atom) @constant
    (alias) @type
    (identifier) @variable
    """

    // MARK: - Haskell
    static let haskell = """
    (comment) @comment
    (string) @string
    (char) @string
    (integer) @number
    (float) @number
    (variable) @variable
    (constructor) @type
    """

    // MARK: - Zig
    static let zig = """
    (comment) @comment
    (string) @string
    (integer) @number
    (float) @number
    (identifier) @variable
    """

    // MARK: - HTML
    static let html = """
    (tag_name) @tag
    (attribute_name) @attribute
    (attribute_value) @string
    (quoted_attribute_value) @string
    (comment) @comment
    (doctype) @keyword
    """

    // MARK: - CSS
    static let css = """
    (tag_name) @tag
    (class_name) @type
    (id_name) @constant
    (property_name) @property
    (color_value) @number
    (integer_value) @number
    (float_value) @number
    (string_value) @string
    (plain_value) @variable
    (comment) @comment
    """
}
