import Foundation

/// Fallback indexer using regex patterns. Always available, no external deps.
public enum RegexBackend {
    /// Language-specific declaration patterns.
    struct LanguagePatterns {
        let language: String
        let patterns: [(kind: SymbolKind, regex: NSRegularExpression)]
    }

    static let allPatterns: [String: LanguagePatterns] = {
        var result: [String: LanguagePatterns] = [:]
        for (lang, defs) in patternDefs {
            let compiled = defs.compactMap { kind, pattern -> (SymbolKind, NSRegularExpression)? in
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines) else { return nil }
                return (kind, regex)
            }
            result[lang] = LanguagePatterns(language: lang, patterns: compiled)
        }
        return result
    }()

    // Pattern definitions per language
    private static let patternDefs: [String: [(SymbolKind, String)]] = [
        "swift": [
            (.function, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?(?:static\s+|class\s+)?(?:override\s+)?func\s+(\w+)"#),
            (.class, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?(?:final\s+)?class\s+(\w+)"#),
            (.struct, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?struct\s+(\w+)"#),
            (.enum, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?enum\s+(\w+)"#),
            (.protocol, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?protocol\s+(\w+)"#),
            (.extension, #"^\s*(?:public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?extension\s+(\w+)"#),
        ],
        "typescript": [
            (.function, #"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)"#),
            (.class, #"^\s*(?:export\s+)?(?:abstract\s+)?class\s+(\w+)"#),
            (.interface, #"^\s*(?:export\s+)?interface\s+(\w+)"#),
            (.type, #"^\s*(?:export\s+)?type\s+(\w+)\s*="#),
            (.function, #"^\s*(?:export\s+)?(?:const|let)\s+(\w+)\s*=\s*(?:async\s+)?\("#),
        ],
        "javascript": [
            (.function, #"^\s*(?:export\s+)?(?:async\s+)?function\s+(\w+)"#),
            (.class, #"^\s*(?:export\s+)?class\s+(\w+)"#),
            (.function, #"^\s*(?:export\s+)?(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s+)?\("#),
        ],
        "python": [
            (.function, #"^(?:async\s+)?def\s+(\w+)\s*\("#),
            (.class, #"^class\s+(\w+)"#),
        ],
        "go": [
            (.function, #"^func\s+(\w+)\s*\("#),
            (.method, #"^func\s+\([^)]+\)\s+(\w+)\s*\("#),
            (.struct, #"^type\s+(\w+)\s+struct\b"#),
            (.interface, #"^type\s+(\w+)\s+interface\b"#),
            (.type, #"^type\s+(\w+)\s+"#),
        ],
        "rust": [
            (.function, #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?fn\s+(\w+)"#),
            (.struct, #"^\s*(?:pub(?:\([^)]*\))?\s+)?struct\s+(\w+)"#),
            (.enum, #"^\s*(?:pub(?:\([^)]*\))?\s+)?enum\s+(\w+)"#),
            (.interface, #"^\s*(?:pub(?:\([^)]*\))?\s+)?trait\s+(\w+)"#),
        ],
        "java": [
            (.class, #"^\s*(?:public\s+|private\s+|protected\s+)?(?:abstract\s+|final\s+)?class\s+(\w+)"#),
            (.interface, #"^\s*(?:public\s+|private\s+|protected\s+)?interface\s+(\w+)"#),
            (.method, #"^\s*(?:public\s+|private\s+|protected\s+)?(?:static\s+)?(?:abstract\s+)?(?:final\s+)?(?:synchronized\s+)?\w+(?:<[^>]+>)?\s+(\w+)\s*\("#),
        ],
        "kotlin": [
            (.class, #"^\s*(?:data\s+|sealed\s+|abstract\s+|open\s+)?class\s+(\w+)"#),
            (.function, #"^\s*(?:suspend\s+)?fun\s+(\w+)"#),
            (.interface, #"^\s*interface\s+(\w+)"#),
        ],
        "ruby": [
            (.class, #"^\s*class\s+(\w+)"#),
            (.method, #"^\s*def\s+(\w+)"#),
        ],
        "c": [
            (.function, #"^(?:\w+\s+)+(\w+)\s*\([^;]*$"#),
            (.struct, #"^\s*(?:typedef\s+)?struct\s+(\w+)"#),
            (.enum, #"^\s*(?:typedef\s+)?enum\s+(\w+)"#),
        ],
        "cpp": [
            (.class, #"^\s*class\s+(\w+)"#),
            (.function, #"^(?:\w+\s+)+(\w+)\s*\([^;]*$"#),
            (.struct, #"^\s*struct\s+(\w+)"#),
        ],
        "zig": [
            (.function, #"^\s*(?:pub\s+)?fn\s+(\w+)"#),
            (.struct, #"^\s*(?:pub\s+)?const\s+(\w+)\s*=\s*struct"#),
            (.enum, #"^\s*(?:pub\s+)?const\s+(\w+)\s*=\s*enum"#),
        ],
    ]

    /// Languages with declaration-pattern coverage in this backend.
    public static var supportedLanguages: Set<String> { Set(allPatterns.keys) }

    /// Whether the regex backend has declaration patterns for `language`.
    public static func supports(_ language: String) -> Bool {
        allPatterns[language] != nil
    }

    /// Index files using regex patterns.
    ///
    /// Throws `IndexError.unsupportedLanguage(language)` if no patterns
    /// are defined for the given language. Per-file unreadable failures
    /// inside the batch are silently skipped — one bad file shouldn't
    /// fail the whole batch — but the setup-level "language not
    /// supported" case is surfaced so callers can distinguish it from
    /// "language supported but no symbols found."
    public static func index(files: [String], language: String, projectRoot: String) throws -> [IndexEntry] {
        guard let langPatterns = allPatterns[language] else {
            throw IndexError.unsupportedLanguage(language)
        }
        var entries: [IndexEntry] = []

        for relativePath in files {
            let fullPath = projectRoot + "/" + relativePath
            guard let content = try? String(contentsOfFile: fullPath, encoding: .utf8) else { continue }
            let lines = content.components(separatedBy: "\n")

            for (lineIdx, line) in lines.enumerated() {
                let lineNum = lineIdx + 1
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)

                for (kind, regex) in langPatterns.patterns {
                    guard let match = regex.firstMatch(in: line, range: range) else { continue }
                    // Extract the captured group (the symbol name)
                    let nameRange = match.range(at: 1)
                    guard nameRange.location != NSNotFound else { continue }
                    let name = nsLine.substring(with: nameRange)

                    // Estimate end line by scanning for matching braces
                    let endLine = estimateEndLine(lines: lines, startIndex: lineIdx)

                    // Get the full line as signature
                    let signature = line.trimmingCharacters(in: .whitespaces)

                    entries.append(IndexEntry(
                        name: name,
                        kind: kind,
                        file: relativePath,
                        startLine: lineNum,
                        endLine: endLine,
                        signature: signature,
                        container: nil,
                        engine: "regex"
                    ))
                    break // one match per line
                }
            }
        }

        return entries
    }

    /// Estimate end line by counting brace depth from start.
    private static func estimateEndLine(lines: [String], startIndex: Int, maxScan: Int = 200) -> Int {
        var depth = 0
        var foundOpen = false
        let limit = min(startIndex + maxScan, lines.count)

        for i in startIndex..<limit {
            for ch in lines[i] {
                if ch == "{" { depth += 1; foundOpen = true }
                if ch == "}" { depth -= 1 }
            }
            if foundOpen && depth <= 0 {
                return i + 1  // 1-based
            }
        }

        // Couldn't find matching brace, return start + reasonable window
        return min(startIndex + 20, lines.count)
    }
}
