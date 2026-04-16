import Testing
import Foundation
@testable import MCPServer

@Suite("WikiLinkCompletion")
struct WikiLinkCompletionTests {

    // 1. Open [[  → returns partial name after the brackets
    @Test func testExtractQueryFromOpenLink() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("some text [[Auth") == "Auth")
    }

    // 2. Closed [[Name]]  → returns nil
    @Test func testExtractQueryNilForClosedLink() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("see [[AuthManager]] for details") == nil)
    }

    // 3. [[  alone → returns empty string (ready for full list)
    @Test func testExtractQueryEmptyStringAfterDoubleOpen() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("text [[") == "")
    }

    // 4. applyCompletion replaces last [[ + partial with [[Candidate]]
    @Test func testApplyCompletionReplacesFull() {
        let result = WikiLinkHelpers.applyCompletion("AuthManager", to: "handles [[Auth")
        #expect(result == "handles [[AuthManager]] ")
    }

    // 5. applyCompletion no-op when no open [[
    @Test func testApplyCompletionNoOpWhenNoBrackets() {
        let input = "plain text with no brackets"
        #expect(WikiLinkHelpers.applyCompletion("Entity", to: input) == input)
    }
}
