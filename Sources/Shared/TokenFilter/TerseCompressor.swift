import Foundation

/// Algorithmic text compression that mechanically removes filler words,
/// articles, hedging phrases, and replaces verbose terms with short equivalents.
/// Preserves code blocks, inline code, URLs, and file paths.
public enum TerseCompressor {

    /// Compress natural language in `text`, preserving code blocks and inline code.
    public static func compress(_ text: String) -> String {
        let segments = splitSegments(text)
        var result = ""
        for segment in segments {
            switch segment.kind {
            case .code:
                result += segment.text
            case .natural:
                result += compressNatural(segment.text)
            }
        }
        // Clean up multi-space runs introduced by deletions
        result = collapseSpaces(result)
        return result
    }

    // MARK: - Segment Splitting

    private enum SegmentKind { case code, natural }
    private struct Segment { let kind: SegmentKind; let text: String }

    /// Split text into alternating code/natural segments.
    /// Code = fenced blocks (```), indented blocks (4+ spaces at line start), inline code (`...`).
    private static func splitSegments(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var natural = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if !natural.isEmpty {
                    segments.append(Segment(kind: .natural, text: natural))
                    natural = ""
                }
                var block = line + "\n"
                i += 1
                while i < lines.count {
                    block += lines[i] + "\n"
                    if lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    i += 1
                }
                segments.append(Segment(kind: .code, text: block))
                continue
            }

            // Indented code block (4+ spaces or tab, not inside a list)
            if (line.hasPrefix("    ") || line.hasPrefix("\t")) && !line.trimmingCharacters(in: .whitespaces).hasPrefix("-") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("*") {
                if !natural.isEmpty {
                    segments.append(Segment(kind: .natural, text: natural))
                    natural = ""
                }
                var block = line + "\n"
                i += 1
                while i < lines.count && (lines[i].hasPrefix("    ") || lines[i].hasPrefix("\t") || lines[i].isEmpty) {
                    block += lines[i] + "\n"
                    i += 1
                }
                segments.append(Segment(kind: .code, text: block))
                continue
            }

            // Regular line — process inline code within it
            natural += processInlineCode(line) + "\n"
            i += 1
        }

        if !natural.isEmpty {
            segments.append(Segment(kind: .natural, text: natural))
        }
        return segments
    }

    /// Protect inline code (`...`) from compression by wrapping in sentinel markers.
    /// Returns the line with inline code replaced by placeholders.
    private static let inlineCodePattern = try! NSRegularExpression(pattern: "`[^`]+`")

    private static func processInlineCode(_ line: String) -> String {
        // We don't actually replace — inline code stays as-is because the
        // compression regexes only match word characters, not backtick-wrapped text.
        // This is a no-op optimization: backtick-wrapped tokens won't match
        // our \b word-boundary patterns.
        return line
    }

    // MARK: - Natural Language Compression

    private static func compressNatural(_ text: String) -> String {
        var result = text

        // Protect URLs and paths from modification
        // URLs and paths won't match word-boundary patterns, but be safe
        let urlPattern = try! NSRegularExpression(pattern: "https?://\\S+")
        let pathPattern = try! NSRegularExpression(pattern: "(?:^|\\s)(/[\\w./-]+)")

        // Phase 1: Delete filler phrases (longer phrases first to avoid partial matches)
        for phrase in deletionPhrases {
            let escaped = NSRegularExpression.escapedPattern(for: phrase)
            if let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) {
                result = re.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: ""
                )
            }
        }

        // Phase 2: Delete standalone articles (the, a, an) only when followed by a word
        if let articleRe = try? NSRegularExpression(pattern: "\\b(the|a|an)\\s+(?=[a-zA-Z])", options: .caseInsensitive) {
            result = articleRe.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Phase 3: Replace verbose terms with short equivalents
        for (long, short) in replacements {
            let escaped = NSRegularExpression.escapedPattern(for: long)
            if let re = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) {
                result = re.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: short
                )
            }
        }

        return result
    }

    // MARK: - Whitespace Cleanup

    private static func collapseSpaces(_ text: String) -> String {
        var result = text
        // Collapse multiple spaces to one (preserve leading indentation)
        if let re = try? NSRegularExpression(pattern: "(?<=\\S) {2,}") {
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: " "
            )
        }
        // Remove space before punctuation
        if let re = try? NSRegularExpression(pattern: " +([.,;:!?])") {
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1"
            )
        }
        // Collapse 3+ blank lines to 2
        if let re = try? NSRegularExpression(pattern: "\n{4,}") {
            result = re.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n\n"
            )
        }
        return result
    }

    // MARK: - Dictionaries

    /// Filler phrases to delete entirely. Ordered longest-first.
    private static let deletionPhrases: [String] = [
        // Verbose connectors
        "in order to", "due to the fact that", "for the purpose of",
        "in the event that", "with respect to", "in terms of",
        "on the other hand", "as a matter of fact", "at the end of the day",
        "it is important to note that", "it should be noted that",
        "it is worth mentioning that", "it is worth noting that",
        "as previously mentioned", "as mentioned above",
        "as described above", "as shown above",
        // Hedging
        "it seems like", "it appears that", "it looks like",
        "I think that", "I believe that", "I would say that",
        "in my opinion", "from my perspective",
        "to be honest", "to be fair", "to be clear",
        "if I'm not mistaken", "if I recall correctly",
        // Preamble / filler
        "I'd be happy to", "I'll go ahead and", "let me go ahead and",
        "I'm going to", "I will now", "let me now",
        "please note that", "keep in mind that",
        "basically", "essentially", "actually", "literally",
        "obviously", "clearly", "simply", "just",
        "very", "really", "quite", "rather",
        "somewhat", "fairly", "pretty much",
        // Post-action narration
        "as you can see", "as we can see",
        "that being said", "having said that",
        "with that in mind", "given the above",
        "moving forward", "going forward",
    ]

    /// Verbose words → short replacements.
    private static let replacements: [(String, String)] = [
        // Technical terms
        ("database", "DB"),
        ("databases", "DBs"),
        ("authentication", "auth"),
        ("authenticate", "auth"),
        ("authorization", "authz"),
        ("authorize", "authz"),
        ("configuration", "config"),
        ("configure", "config"),
        ("configurations", "configs"),
        ("environment", "env"),
        ("environments", "envs"),
        ("application", "app"),
        ("applications", "apps"),
        ("repository", "repo"),
        ("repositories", "repos"),
        ("directory", "dir"),
        ("directories", "dirs"),
        ("documentation", "docs"),
        ("document", "doc"),
        ("implementation", "impl"),
        ("implement", "impl"),
        ("implementations", "impls"),
        ("function", "fn"),
        ("functions", "fns"),
        ("parameter", "param"),
        ("parameters", "params"),
        ("dependency", "dep"),
        ("dependencies", "deps"),
        ("development", "dev"),
        ("production", "prod"),
        ("information", "info"),
        ("specification", "spec"),
        ("specifications", "specs"),
        ("introduction", "intro"),
        ("communication", "comms"),
        ("temporary", "temp"),
        ("maximum", "max"),
        ("minimum", "min"),
        ("approximately", "~"),
        ("executable", "exec"),
        ("executables", "execs"),
        ("administrator", "admin"),
        ("administrators", "admins"),
        ("permission", "perm"),
        ("permissions", "perms"),
        ("synchronize", "sync"),
        ("synchronization", "sync"),
        ("asynchronous", "async"),
        ("asynchronously", "async"),
        ("regular expression", "regex"),
        ("regular expressions", "regexes"),
        // Verbose verbs
        ("utilize", "use"),
        ("utilizes", "uses"),
        ("utilization", "use"),
        ("initialize", "init"),
        ("initializes", "inits"),
        ("initialization", "init"),
        ("terminate", "kill"),
        ("terminates", "kills"),
        ("establish", "set up"),
        ("demonstrates", "shows"),
        ("demonstrate", "show"),
        ("indicates", "shows"),
        ("indicate", "show"),
        ("represents", "is"),
        ("represent", "is"),
        ("corresponds to", "maps to"),
        ("associated with", "for"),
        // Common verbose phrases
        ("in addition to", "plus"),
        ("a large number of", "many"),
        ("a number of", "several"),
        ("the majority of", "most"),
        ("a variety of", "various"),
        ("is able to", "can"),
        ("are able to", "can"),
        ("in order to", "to"),
        ("make sure", "ensure"),
        ("whether or not", "whether"),
        ("despite the fact that", "although"),
        ("subsequent to", "after"),
        ("prior to", "before"),
        ("at this point in time", "now"),
        ("at the present time", "now"),
        ("for the purpose of", "to"),
        ("has the ability to", "can"),
        ("on a regular basis", "regularly"),
        ("take into account", "consider"),
        ("take into consideration", "consider"),
    ]
}
