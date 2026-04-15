import Testing
import Foundation
@testable import MCPServer

@Suite("Symbol Staleness Notifications")
struct SymbolStalenessTests {

    private func makeSession() -> MCPSession {
        MCPSession(projectRoot: "/tmp/staleness-test-\(UUID().uuidString)")
    }

    @Test func queryThenChangeGeneratesNotice() {
        let session = makeSession()

        session.trackQueriedSymbol(file: "Sources/Core/Foo.swift")
        session.checkStaleness(changedFiles: Set(["Sources/Core/Foo.swift"]))

        let notices = session.drainStaleNotices()
        #expect(notices.count == 1, "Should have 1 notice")
        #expect(notices.first?.contains("[stale]") == true)
        #expect(notices.first?.contains("Foo.swift") == true)
    }

    @Test func noticeClearedAfterDelivery() {
        let session = makeSession()

        session.trackQueriedSymbol(file: "bar.swift")
        session.checkStaleness(changedFiles: Set(["bar.swift"]))

        let first = session.drainStaleNotices()
        #expect(!first.isEmpty, "First drain should have notices")

        let second = session.drainStaleNotices()
        #expect(second.isEmpty, "Second drain should be empty")
    }

    @Test func multipleStaleCoalesced() {
        let session = makeSession()

        session.trackQueriedSymbol(file: "a.swift")
        session.trackQueriedSymbol(file: "b.swift")
        session.trackQueriedSymbol(file: "c.swift")

        session.checkStaleness(changedFiles: Set(["a.swift", "b.swift", "c.swift"]))

        let notices = session.drainStaleNotices()
        #expect(notices.count == 1, "Multiple stale files should coalesce into 1 notice")
        #expect(notices.first?.contains("a.swift") == true)
        #expect(notices.first?.contains("b.swift") == true)
        #expect(notices.first?.contains("c.swift") == true)
    }

    @Test func noNoticeForUnqueriedFile() {
        let session = makeSession()

        session.trackQueriedSymbol(file: "queried.swift")
        session.checkStaleness(changedFiles: Set(["unrelated.swift"]))

        let notices = session.drainStaleNotices()
        #expect(notices.isEmpty, "No notice should be generated for unqueried files")
    }
}
