import Testing
@testable import Filter

@Suite("ANSIStripper") struct ANSIStripperTests {
    @Test func stripColors() {
        let input = "\u{1B}[31mERROR\u{1B}[0m: something failed"
        #expect(ANSIStripper.strip(input) == "ERROR: something failed")
    }

    @Test func stripBold() {
        let input = "\u{1B}[1mBold text\u{1B}[0m"
        #expect(ANSIStripper.strip(input) == "Bold text")
    }

    @Test func stripOSC() {
        let input = "\u{1B}]0;window title\u{07}Hello"
        #expect(ANSIStripper.strip(input) == "Hello")
    }

    @Test func plainText() {
        let input = "Hello, world!"
        #expect(ANSIStripper.strip(input) == input)
    }

    @Test func emptyString() {
        #expect(ANSIStripper.strip("") == "")
    }

    @Test func multipleSequences() {
        let input = "\u{1B}[32m✓\u{1B}[0m test passed \u{1B}[90m(0.5s)\u{1B}[0m"
        #expect(ANSIStripper.strip(input) == "✓ test passed (0.5s)")
    }

    @Test func incompleteEscape() {
        let input = "hello\u{1B}"
        let result = ANSIStripper.strip(input)
        #expect(result == "hello")
    }

    @Test func cursorMovement() {
        let input = "\u{1B}[2Jhello\u{1B}[H"
        #expect(ANSIStripper.strip(input) == "hello")
    }
}
