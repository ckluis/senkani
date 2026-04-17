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

    // 6. Closed link followed by a fresh open → the OPEN one wins because
    //    `.backwards` finds the last `[[`, which is the one still awaiting
    //    completion. Guards against a regression where the completion UI
    //    would pop up while the user types inside an already-completed
    //    wiki-link earlier in the document.
    @Test func testExtractQueryOpenAfterClosed() {
        #expect(
            WikiLinkHelpers.extractWikiLinkQuery("see [[Foo]] and now [[Ba")
                == "Ba"
        )
    }

    // 7. `[[` at the very start of a line still resolves. Typing a wiki-link
    //    as the first characters of the file is a real author flow.
    @Test func testExtractQueryAtStringStart() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("[[Index") == "Index")
    }

    // 8. Empty string is a trivial input that must produce nil, not crash.
    @Test func testExtractQueryOnEmpty() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("") == nil)
    }

    // 9. Single `[` is not a wiki-link opener — only the double form
    //    triggers completion. Prevents false positives on markdown `[text](url)`.
    @Test func testExtractQueryRejectsSingleBracket() {
        #expect(WikiLinkHelpers.extractWikiLinkQuery("see [Ref") == nil)
    }

    // 10. Partial name with spaces — the suffix after the last `[[` is
    //     returned verbatim, so a multi-word partial still round-trips.
    @Test func testExtractQueryWithSpacesInPartial() {
        #expect(
            WikiLinkHelpers.extractWikiLinkQuery("note [[Auth Provider")
                == "Auth Provider"
        )
    }

    // 11. applyCompletion replaces only the LAST open `[[`, leaving an
    //     earlier closed wiki-link untouched. Critical for multi-link docs.
    @Test func testApplyCompletionPreservesEarlierClosedLinks() {
        let result = WikiLinkHelpers.applyCompletion(
            "BaseClass", to: "see [[Foo]] extends [[Ba"
        )
        #expect(result == "see [[Foo]] extends [[BaseClass]] ")
    }

    // 12. applyCompletion preserves text before the last `[[` byte-for-byte.
    @Test func testApplyCompletionPreservesPrefix() {
        let result = WikiLinkHelpers.applyCompletion("Target", to: "prefix \t\n [[pa")
        #expect(result.hasPrefix("prefix \t\n "))
        #expect(result.hasSuffix("[[Target]] "))
    }

    // 13. extract → apply round-trip: the extracted partial plus the
    //     completion candidate should produce the same string as calling
    //     applyCompletion directly. Guards against subtle index drift.
    @Test func testRoundTripExtractThenApply() {
        let input = "the [[Acc"
        let query = WikiLinkHelpers.extractWikiLinkQuery(input)
        #expect(query == "Acc")
        let completed = WikiLinkHelpers.applyCompletion("Account", to: input)
        #expect(completed == "the [[Account]] ")
    }

    // 14. Candidate containing spaces (multi-word entity name) is wrapped
    //     correctly — matches the typical KB entity-name format.
    @Test func testApplyCompletionWithSpacedCandidate() {
        let result = WikiLinkHelpers.applyCompletion("Session Database", to: "uses [[Ses")
        #expect(result == "uses [[Session Database]] ")
    }
}
