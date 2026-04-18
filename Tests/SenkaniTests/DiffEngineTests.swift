import Testing
@testable import Core

@Suite("DiffEngine") struct DiffEngineTests {

    // MARK: - computeHunks

    @Test func noChangeProducesZeroHunks() {
        let text = "alpha\nbeta\ngamma"
        let hunks = DiffEngine.computeHunks(original: text, modified: text)
        #expect(hunks.isEmpty)
    }

    @Test func midFileInsertionProducesOneHunk() {
        let original = "alpha\nbeta\ngamma"
        let modified = "alpha\nbeta\nNEW\ngamma"
        let hunks = DiffEngine.computeHunks(original: original, modified: modified)
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines.isEmpty)
        #expect(hunks[0].addedLines == ["NEW"])
    }

    @Test func midFileDeletionProducesOneHunk() {
        let original = "alpha\nbeta\ngamma\ndelta"
        let modified = "alpha\ngamma\ndelta"
        let hunks = DiffEngine.computeHunks(original: original, modified: modified)
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines == ["beta"])
        #expect(hunks[0].addedLines.isEmpty)
    }

    @Test func midFileReplacementPairsRemoveAndAdd() {
        let original = "alpha\nOLD\ngamma"
        let modified = "alpha\nNEW\ngamma"
        let hunks = DiffEngine.computeHunks(original: original, modified: modified)
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines == ["OLD"])
        #expect(hunks[0].addedLines == ["NEW"])
    }

    @Test func whitespaceOnlyChangeShowsAsRemoveAndAdd() {
        let original = "alpha\n  beta  \ngamma"
        let modified = "alpha\nbeta\ngamma"
        let hunks = DiffEngine.computeHunks(original: original, modified: modified)
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines == ["  beta  "])
        #expect(hunks[0].addedLines == ["beta"])
    }

    // MARK: - computePairedLines

    @Test func pairedLinesAlignOnNoChange() {
        let text = "a\nb\nc"
        let paired = DiffEngine.computePairedLines(original: text, modified: text)
        #expect(paired.left.count == 3)
        #expect(paired.right.count == 3)
        #expect(paired.left.allSatisfy { $0.kind == .unchanged })
        #expect(paired.right.allSatisfy { $0.kind == .unchanged })
        #expect(paired.left.map(\.text) == ["a", "b", "c"])
        #expect(paired.right.map(\.text) == ["a", "b", "c"])
    }

    @Test func pairedLinesInsertionPadsLeftColumn() {
        let original = "a\nc"
        let modified = "a\nb\nc"
        let paired = DiffEngine.computePairedLines(original: original, modified: modified)
        #expect(paired.left.count == 3)
        #expect(paired.right.count == 3)
        // Row for the inserted "b": left must be an empty unchanged placeholder
        // so column alignment is preserved; right must be the added line.
        #expect(paired.left[1] == DiffLine(text: "", kind: .unchanged))
        #expect(paired.right[1] == DiffLine(text: "b", kind: .added))
        #expect(paired.left[0].kind == .unchanged && paired.left[0].text == "a")
        #expect(paired.left[2].kind == .unchanged && paired.left[2].text == "c")
    }

    @Test func pairedLinesDeletionPadsRightColumn() {
        let original = "a\nb\nc"
        let modified = "a\nc"
        let paired = DiffEngine.computePairedLines(original: original, modified: modified)
        #expect(paired.left.count == 3)
        #expect(paired.right.count == 3)
        #expect(paired.left[1] == DiffLine(text: "b", kind: .removed))
        #expect(paired.right[1] == DiffLine(text: "", kind: .unchanged))
    }

    @Test func pairedLinesReplacementAppearsOnSameRow() {
        let original = "alpha\nOLD\ngamma"
        let modified = "alpha\nNEW\ngamma"
        let paired = DiffEngine.computePairedLines(original: original, modified: modified)
        #expect(paired.left.count == 3)
        #expect(paired.right.count == 3)
        #expect(paired.left[1] == DiffLine(text: "OLD", kind: .removed))
        #expect(paired.right[1] == DiffLine(text: "NEW", kind: .added))
    }

    @Test func pairedLinesMismatchedReplacementRunPadsExcess() {
        // 3 removes vs 1 add: row 0 pairs, rows 1 and 2 get right-side padding.
        let original = "top\nR1\nR2\nR3\nbot"
        let modified = "top\nA1\nbot"
        let paired = DiffEngine.computePairedLines(original: original, modified: modified)
        #expect(paired.left.count == 5)
        #expect(paired.right.count == 5)
        #expect(paired.left[1] == DiffLine(text: "R1", kind: .removed))
        #expect(paired.right[1] == DiffLine(text: "A1", kind: .added))
        #expect(paired.left[2] == DiffLine(text: "R2", kind: .removed))
        #expect(paired.right[2] == DiffLine(text: "", kind: .unchanged))
        #expect(paired.left[3] == DiffLine(text: "R3", kind: .removed))
        #expect(paired.right[3] == DiffLine(text: "", kind: .unchanged))
    }

    // MARK: - Large file scale

    @Test func largeFileOver1000LinesCompletesAndIsCorrect() {
        // 1200 identical lines with one mid-file change. Must complete quickly
        // and produce exactly one hunk at the expected position.
        var lines: [String] = []
        for i in 0..<1200 { lines.append("line-\(i)") }
        let original = lines.joined(separator: "\n")
        lines[600] = "line-600-MODIFIED"
        let modified = lines.joined(separator: "\n")

        let hunks = DiffEngine.computeHunks(original: original, modified: modified)
        #expect(hunks.count == 1)
        #expect(hunks[0].removedLines == ["line-600"])
        #expect(hunks[0].addedLines == ["line-600-MODIFIED"])

        let paired = DiffEngine.computePairedLines(original: original, modified: modified)
        #expect(paired.left.count == 1200)
        #expect(paired.right.count == 1200)
        #expect(paired.left[600] == DiffLine(text: "line-600", kind: .removed))
        #expect(paired.right[600] == DiffLine(text: "line-600-MODIFIED", kind: .added))
    }

    // MARK: - applyResolutions round-trip

    @Test func applyResolutionsAcceptKeepsModified() {
        let original = "a\nOLD\nc"
        let modified = "a\nNEW\nc"
        var hunks = DiffEngine.computeHunks(original: original, modified: modified)
        hunks[0].resolution = true
        let result = DiffEngine.applyResolutions(original: original, modified: modified, hunks: hunks)
        #expect(result == "a\nNEW\nc")
    }

    @Test func applyResolutionsRejectRevertsToOriginal() {
        let original = "a\nOLD\nc"
        let modified = "a\nNEW\nc"
        var hunks = DiffEngine.computeHunks(original: original, modified: modified)
        hunks[0].resolution = false
        let result = DiffEngine.applyResolutions(original: original, modified: modified, hunks: hunks)
        #expect(result == "a\nOLD\nc")
    }
}
