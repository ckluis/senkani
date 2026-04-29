import Foundation

/// Streaming Markdown → ANSI transcoder.
///
/// Mirrors the `@wterm/markdown` per-line dispatcher pattern from
/// `spec/inspirations/native-app-ux/wterm.md`: incomplete tails are
/// buffered, complete lines are emitted as ANSI-styled text, and
/// fenced code blocks are accumulated across deltas until the
/// closing fence arrives. The only state is `_buffer` and
/// `_inCodeBlock` (plus the language hint for the open fence).
///
/// Designed for MCP-streaming text responses — push delta chunks
/// as they arrive, drain finished lines, and call `flush()` at the
/// end of the stream to emit any orphan tail.
public final class MarkdownStreamingTranscoder {
    private var buffer: String = ""
    private var inCodeBlock: Bool = false
    private var codeFenceLanguage: String = ""

    public init() {}

    /// Append a delta and return ANSI bytes for any newly completed
    /// lines. The trailing partial line (if any) stays buffered for
    /// the next call.
    public func push(_ delta: String) -> String {
        buffer.append(delta)
        var output = ""
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            output.append(processLine(line))
        }
        return output
    }

    /// Drain remaining state at end-of-stream. Emits any unterminated
    /// tail line and closes an orphan code block. After `flush()`,
    /// the transcoder is reset to a fresh stream.
    public func flush() -> String {
        var output = ""
        if !buffer.isEmpty {
            let tail = buffer
            buffer = ""
            output.append(processLine(tail))
        }
        if inCodeBlock {
            output.append(Ansi.reset)
            inCodeBlock = false
            codeFenceLanguage = ""
        }
        return output
    }

    // MARK: - Line dispatcher

    private func processLine(_ line: String) -> String {
        if inCodeBlock {
            if isCodeFence(line) {
                inCodeBlock = false
                codeFenceLanguage = ""
                return Ansi.reset + "\n"
            }
            return Ansi.codeBlock + line + Ansi.reset + "\n"
        }
        if isCodeFence(line) {
            inCodeBlock = true
            codeFenceLanguage = codeFenceLanguageHint(line)
            let header = codeFenceLanguage.isEmpty
                ? Ansi.dim + "─── code ───" + Ansi.reset
                : Ansi.dim + "─── code (\(codeFenceLanguage)) ───" + Ansi.reset
            return header + "\n"
        }
        return formatBlockLine(line) + "\n"
    }

    // MARK: - Block-level formatting

    private func formatBlockLine(_ raw: String) -> String {
        if raw.isEmpty { return "" }
        let trimmedLeft = raw.drop(while: { $0 == " " })
        let leadingSpaces = String(repeating: " ", count: raw.count - trimmedLeft.count)

        if trimmedLeft.hasPrefix("> ") {
            let body = String(trimmedLeft.dropFirst(2))
            return leadingSpaces + Ansi.dim + "│ " + Ansi.italic + applyInline(body) + Ansi.reset
        }
        if let heading = matchHeading(String(trimmedLeft)) {
            return leadingSpaces + Ansi.heading + heading + Ansi.reset
        }
        if let bullet = matchBullet(String(trimmedLeft)) {
            return leadingSpaces + Ansi.dim + bullet.marker + Ansi.reset + " " + applyInline(bullet.body)
        }
        if let ordered = matchOrderedItem(String(trimmedLeft)) {
            return leadingSpaces + Ansi.dim + ordered.marker + Ansi.reset + " " + applyInline(ordered.body)
        }
        return applyInline(raw)
    }

    private func matchHeading(_ line: String) -> String? {
        var hashes = 0
        for ch in line {
            if ch == "#" { hashes += 1 } else { break }
            if hashes > 6 { return nil }
        }
        guard hashes >= 1, hashes <= 6 else { return nil }
        let after = line.index(line.startIndex, offsetBy: hashes)
        guard after < line.endIndex, line[after] == " " else { return nil }
        let body = String(line[line.index(after: after)...])
        let prefix = String(repeating: "#", count: hashes)
        return prefix + " " + applyInline(body)
    }

    private struct ListItem { let marker: String; let body: String }

    private func matchBullet(_ line: String) -> ListItem? {
        guard let first = line.first, first == "-" || first == "*" || first == "+" else { return nil }
        let rest = line.dropFirst()
        guard rest.first == " " else { return nil }
        let body = String(rest.dropFirst())
        return ListItem(marker: String(first), body: body)
    }

    private func matchOrderedItem(_ line: String) -> ListItem? {
        var idx = line.startIndex
        var digits = 0
        while idx < line.endIndex, line[idx].isASCII, line[idx].isNumber {
            digits += 1
            idx = line.index(after: idx)
        }
        guard digits > 0, idx < line.endIndex, line[idx] == "." else { return nil }
        let afterDot = line.index(after: idx)
        guard afterDot < line.endIndex, line[afterDot] == " " else { return nil }
        let marker = String(line[line.startIndex...idx])
        let body = String(line[line.index(after: afterDot)...])
        return ListItem(marker: marker, body: body)
    }

    // MARK: - Inline scanner
    //
    // Single forward pass over the line. Scanned in order so that
    // earlier markers don't get re-scanned: backtick code spans win
    // over emphasis (their content is pasted verbatim), bold (`**`)
    // is matched before italic (`*`), and links `[text](url)` are
    // matched as their own form. Anything that fails to match a
    // closing delimiter falls through as literal text.

    private func applyInline(_ input: String) -> String {
        var output = ""
        let scalars = Array(input)
        var i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "`" {
                if let close = findClosing(scalars, "`", from: i + 1) {
                    let body = String(scalars[(i + 1)..<close])
                    output.append(Ansi.code + body + Ansi.codeOff)
                    i = close + 1
                    continue
                }
            }
            if c == "*" || c == "_" {
                if i + 1 < scalars.count, scalars[i + 1] == c {
                    if let close = findClosingDouble(scalars, c, from: i + 2) {
                        let body = String(scalars[(i + 2)..<close])
                        output.append(Ansi.bold + applyInline(body) + Ansi.boldOff)
                        i = close + 2
                        continue
                    }
                } else {
                    if let close = findClosing(scalars, c, from: i + 1) {
                        let body = String(scalars[(i + 1)..<close])
                        output.append(Ansi.italic + applyInline(body) + Ansi.italicOff)
                        i = close + 1
                        continue
                    }
                }
            }
            if c == "[" {
                if let result = matchLink(scalars, from: i) {
                    output.append(Ansi.linkOn + applyInline(result.text) + Ansi.linkOff)
                    if !result.url.isEmpty {
                        output.append(" " + Ansi.dim + "(" + result.url + ")" + Ansi.reset)
                    }
                    i = result.end
                    continue
                }
            }
            output.append(c)
            i += 1
        }
        return output
    }

    private func findClosing(_ scalars: [Character], _ marker: Character, from start: Int) -> Int? {
        var i = start
        while i < scalars.count {
            if scalars[i] == marker {
                if marker == "*" || marker == "_" {
                    if i + 1 < scalars.count, scalars[i + 1] == marker { i += 2; continue }
                }
                return i
            }
            i += 1
        }
        return nil
    }

    private func findClosingDouble(_ scalars: [Character], _ marker: Character, from start: Int) -> Int? {
        var i = start
        while i < scalars.count - 1 {
            if scalars[i] == marker, scalars[i + 1] == marker { return i }
            i += 1
        }
        return nil
    }

    private struct LinkMatch { let text: String; let url: String; let end: Int }

    private func matchLink(_ scalars: [Character], from start: Int) -> LinkMatch? {
        guard scalars[start] == "[" else { return nil }
        var i = start + 1
        var depth = 1
        while i < scalars.count {
            if scalars[i] == "[" { depth += 1 }
            if scalars[i] == "]" { depth -= 1; if depth == 0 { break } }
            i += 1
        }
        guard i < scalars.count, scalars[i] == "]" else { return nil }
        let textEnd = i
        i += 1
        guard i < scalars.count, scalars[i] == "(" else { return nil }
        let urlStart = i + 1
        i = urlStart
        while i < scalars.count, scalars[i] != ")" { i += 1 }
        guard i < scalars.count, scalars[i] == ")" else { return nil }
        let text = String(scalars[(start + 1)..<textEnd])
        let url = String(scalars[urlStart..<i])
        return LinkMatch(text: text, url: url, end: i + 1)
    }

    // MARK: - Code fence detection

    private func isCodeFence(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private func codeFenceLanguageHint(_ line: String) -> String {
        let trimmed = line.drop(while: { $0 == " " })
        let after = trimmed.dropFirst(3)
        return after.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Convenience

    /// Transcode a complete (non-streaming) markdown string in one
    /// shot. Equivalent to `push(input)` followed by `flush()`.
    public static func transcode(_ input: String) -> String {
        let t = MarkdownStreamingTranscoder()
        var out = t.push(input)
        out.append(t.flush())
        return out
    }
}

// MARK: - ANSI palette

private enum Ansi {
    static let reset = "\u{1B}[0m"
    static let bold = "\u{1B}[1m"
    static let boldOff = "\u{1B}[22m"
    static let italic = "\u{1B}[3m"
    static let italicOff = "\u{1B}[23m"
    static let dim = "\u{1B}[2m"
    static let heading = "\u{1B}[1;36m"   // bold cyan
    static let code = "\u{1B}[7m"          // inverse video for inline code
    static let codeOff = "\u{1B}[27m"
    static let codeBlock = "\u{1B}[2;36m" // dim cyan for fenced code body
    static let linkOn = "\u{1B}[4;34m"     // underlined blue
    static let linkOff = "\u{1B}[24;39m"
}
