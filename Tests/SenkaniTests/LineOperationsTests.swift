import Testing
@testable import Filter

@Suite("LineOperations") struct LineOperationsTests {
    // MARK: - head

    @Test func headBasic() {
        let input = "line1\nline2\nline3\nline4\nline5"
        let result = LineOperations.head(input, count: 3)
        #expect(result.contains("line1"))
        #expect(result.contains("line3"))
        #expect(result.contains("2 lines truncated"))
        #expect(!result.contains("line4"))
    }

    @Test func headShort() {
        let input = "line1\nline2"
        #expect(LineOperations.head(input, count: 5) == input)
    }

    // MARK: - tail

    @Test func tailBasic() {
        let input = "line1\nline2\nline3\nline4\nline5"
        let result = LineOperations.tail(input, count: 2)
        #expect(result.contains("line4"))
        #expect(result.contains("line5"))
        #expect(result.contains("3 lines truncated"))
    }

    @Test func tailShort() {
        let input = "line1\nline2"
        #expect(LineOperations.tail(input, count: 5) == input)
    }

    // MARK: - truncateBytes

    @Test func truncateBasic() {
        let input = "short\nmedium line\nthis is a very long line that pushes us over"
        let result = LineOperations.truncateBytes(input, max: 20)
        #expect(result.contains("short"))
        #expect(result.contains("truncated at 20 bytes"))
    }

    @Test func truncateUnderLimit() {
        let input = "short"
        #expect(LineOperations.truncateBytes(input, max: 100) == input)
    }

    // MARK: - stripMatching

    @Test func stripMatchingBasic() {
        let input = "keep this\nREMOVE this line\nkeep this too\nREMOVE another"
        let result = LineOperations.stripMatching(input, pattern: "REMOVE")
        #expect(result.contains("keep this"))
        #expect(result.contains("keep this too"))
        #expect(!result.contains("REMOVE this"))
        #expect(result.contains("2 lines filtered"))
    }

    // MARK: - keepMatching

    @Test func keepMatchingBasic() {
        let input = "error: bad thing\ninfo: good thing\nerror: another bad"
        let result = LineOperations.keepMatching(input, pattern: "error")
        #expect(result.contains("error: bad thing"))
        #expect(result.contains("error: another bad"))
        #expect(!result.contains("info"))
    }

    // MARK: - dedup

    @Test func dedupBasic() {
        let input = "line1\nline1\nline1\nline2\nline2"
        let result = LineOperations.dedup(input)
        #expect(result.contains("line1 (repeated 3x)"))
        #expect(result.contains("line2 (repeated 2x)"))
    }

    @Test func dedupNonConsecutive() {
        let input = "a\nb\na\nb"
        let result = LineOperations.dedup(input)
        // No grouping since they're not consecutive
        #expect(!result.contains("repeated"))
    }

    // MARK: - groupSimilar

    @Test func groupSimilarBasic() {
        // Use short lines where first 20 chars match (prefix comparison)
        let input = "Downloading package number one from registry\nDownloading package number two from registry\nDownloading package number three from registry\nDownloading package number four from registry\nDone."
        let result = LineOperations.groupSimilar(input, threshold: 3)
        #expect(result.contains("Downloading package number one"))
        #expect(result.contains("similar lines"))
        #expect(result.contains("Done."))
    }

    @Test func groupSimilarBelowThreshold() {
        let input = "Downloading a\nDownloading b\nDone"
        let result = LineOperations.groupSimilar(input, threshold: 3)
        #expect(result.contains("Downloading a"))
        #expect(result.contains("Downloading b"))
        #expect(!result.contains("similar"))
    }

    // MARK: - stripBlankRuns

    @Test func stripBlankRunsBasic() {
        let input = "line1\n\n\n\n\nline2"
        let result = LineOperations.stripBlankRuns(input, max: 1)
        // Should have at most 1 blank line between line1 and line2
        let lines = result.split(separator: "\n", omittingEmptySubsequences: false)
        var maxConsecutiveBlanks = 0
        var current = 0
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                current += 1
                maxConsecutiveBlanks = max(maxConsecutiveBlanks, current)
            } else {
                current = 0
            }
        }
        #expect(maxConsecutiveBlanks <= 1)
    }

    // MARK: - empty input

    @Test func emptyInput() {
        #expect(LineOperations.head("", count: 5) == "")
        #expect(LineOperations.tail("", count: 5) == "")
        #expect(LineOperations.dedup("") == "")
        #expect(LineOperations.stripMatching("", pattern: "x") == "")
        #expect(LineOperations.keepMatching("", pattern: "x") == "")
    }
}
