import Foundation
import Testing
@testable import Core

@Suite("MarkdownStreamingTranscoder") struct MarkdownStreamingTranscoderTests {

    /// Strip ANSI escape sequences so assertions can focus on the
    /// emitted *text* contract independently of the styling palette.
    private static func plain(_ ansi: String) -> String {
        var out = ""
        out.reserveCapacity(ansi.count)
        var iter = ansi.makeIterator()
        while let ch = iter.next() {
            if ch == "\u{1B}" {
                guard let next = iter.next() else { break }
                if next == "[" {
                    while let c = iter.next() { if c >= "@" && c <= "~" { break } }
                }
                continue
            }
            out.append(ch)
        }
        return out
    }

    // 1. Per-line buffering: a partial line is held until its newline
    //    arrives. This is the load-bearing wterm pattern.
    @Test func bufferOnIncompleteLine() {
        let t = MarkdownStreamingTranscoder()
        #expect(t.push("hello, ") == "")
        #expect(t.push("world").isEmpty)
        let final = t.push("\n")
        #expect(Self.plain(final) == "hello, world\n")
    }

    // 2. Multi-chunk push across two complete lines.
    @Test func multiChunkLines() {
        let t = MarkdownStreamingTranscoder()
        var out = ""
        out += t.push("first line\nseco")
        out += t.push("nd line\n")
        #expect(Self.plain(out) == "first line\nsecond line\n")
    }

    // 3. Code fence boundary: the opening fence opens a code block,
    //    interior lines stream through verbatim (no inline scan),
    //    and the closing fence ends the block.
    @Test func codeFenceBoundary() {
        let t = MarkdownStreamingTranscoder()
        var out = ""
        out += t.push("```swift\n")
        out += t.push("let x = **not bold**\n")
        out += t.push("```\n")
        let plain = Self.plain(out)
        #expect(plain.contains("code (swift)"))
        #expect(plain.contains("let x = **not bold**"))
        // The asterisks inside the block must not trigger inline bold —
        // i.e. they survive verbatim.
        #expect(plain.contains("**not bold**"))
    }

    // 4. Inline bold + italic in a single line.
    @Test func inlineBoldItalic() {
        let t = MarkdownStreamingTranscoder()
        let out = t.push("This is **bold** and *italic*.\n")
        let plain = Self.plain(out)
        #expect(plain == "This is bold and italic.\n")
        // Style escapes are present in the raw output.
        #expect(out.contains("\u{1B}[1m"))
        #expect(out.contains("\u{1B}[3m"))
    }

    // 5. Inline code span — backtick contents must NOT be re-scanned
    //    for emphasis. Asterisks inside `code` survive.
    @Test func inlineCodeProtects() {
        let t = MarkdownStreamingTranscoder()
        let out = t.push("see `*not italic*` here\n")
        let plain = Self.plain(out)
        #expect(plain == "see *not italic* here\n")
    }

    // 6. Heading and link rendering.
    @Test func headingAndLink() {
        let t = MarkdownStreamingTranscoder()
        var out = ""
        out += t.push("# Title\n")
        out += t.push("see [docs](https://example.com) please\n")
        let plain = Self.plain(out)
        #expect(plain.contains("# Title"))
        #expect(plain.contains("docs (https://example.com)"))
    }

    // 7. flush() drains an orphan code block + an unterminated tail.
    @Test func flushDrainsOrphanCodeBlock() {
        let t = MarkdownStreamingTranscoder()
        var out = ""
        out += t.push("```\n")
        out += t.push("body\n")
        out += t.push("trailing without newline")
        out += t.flush()
        let plain = Self.plain(out)
        #expect(plain.contains("body"))
        // Trailing tail without newline is emitted on flush as a code
        // line (still inside the open fence).
        #expect(plain.contains("trailing without newline"))
    }

    // 8. Streaming jitter benchmark — a 5K-character markdown corpus
    //    pushed one byte at a time must transcode well under the
    //    "<3 frames jitter" budget. At a 60 Hz frame budget of
    //    16.67 ms, three frames is 50 ms; we assert <50 ms wall.
    @Test func streamingJitterBudget() {
        var corpus = ""
        let block = """
            # Heading

            Some **bold** and *italic* and `code` and [link](https://x.test).

            - item one
            - item two

            ```swift
            let x = 42
            print(x)
            ```

            > a blockquote

            """
        while corpus.count < 5000 { corpus.append(block) }
        let bytes = Array(corpus)
        let t = MarkdownStreamingTranscoder()
        let start = Date()
        for ch in bytes { _ = t.push(String(ch)) }
        _ = t.flush()
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 0.050, "transcode took \(elapsed * 1000) ms (>50ms)")
    }

    // 9. Bullet and ordered list markers are kept; bodies retain inline
    //    formatting.
    @Test func listItems() {
        let t = MarkdownStreamingTranscoder()
        var out = ""
        out += t.push("- alpha **b**\n")
        out += t.push("1. first\n")
        let plain = Self.plain(out)
        #expect(plain.contains("- alpha b"))
        #expect(plain.contains("1. first"))
    }

    // 10. transcode(_:) static convenience runs push + flush in one shot.
    @Test func staticTranscode() {
        let plain = Self.plain(MarkdownStreamingTranscoder.transcode("**hi**\n"))
        #expect(plain == "hi\n")
    }
}
