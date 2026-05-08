import Testing
import Foundation
@testable import MCPServer

@Suite("Symbol Staleness Notifications")
struct SymbolStalenessTests {

    private func makeSession() -> MCPSession {
        MCPSession(projectRoot: "/tmp/staleness-test-\(UUID().uuidString)")
    }

    @Test func queryThenChangeGeneratesNotice() async {
        let session = makeSession()

        await session.trackQueriedSymbol(file: "Sources/Core/Foo.swift")
        await session.checkStaleness(changedFiles: Set(["Sources/Core/Foo.swift"]))

        let notices = await session.drainStaleNotices()
        #expect(notices.count == 1, "Should have 1 notice")
        #expect(notices.first?.contains("[stale]") == true)
        #expect(notices.first?.contains("Foo.swift") == true)
    }

    @Test func noticeClearedAfterDelivery() async {
        let session = makeSession()

        await session.trackQueriedSymbol(file: "bar.swift")
        await session.checkStaleness(changedFiles: Set(["bar.swift"]))

        let first = await session.drainStaleNotices()
        #expect(!first.isEmpty, "First drain should have notices")

        let second = await session.drainStaleNotices()
        #expect(second.isEmpty, "Second drain should be empty")
    }

    @Test func multipleStaleCoalesced() async {
        let session = makeSession()

        await session.trackQueriedSymbol(file: "a.swift")
        await session.trackQueriedSymbol(file: "b.swift")
        await session.trackQueriedSymbol(file: "c.swift")

        await session.checkStaleness(changedFiles: Set(["a.swift", "b.swift", "c.swift"]))

        let notices = await session.drainStaleNotices()
        #expect(notices.count == 1, "Multiple stale files should coalesce into 1 notice")
        #expect(notices.first?.contains("a.swift") == true)
        #expect(notices.first?.contains("b.swift") == true)
        #expect(notices.first?.contains("c.swift") == true)
    }

    @Test func noNoticeForUnqueriedFile() async {
        let session = makeSession()

        await session.trackQueriedSymbol(file: "queried.swift")
        await session.checkStaleness(changedFiles: Set(["unrelated.swift"]))

        let notices = await session.drainStaleNotices()
        #expect(notices.isEmpty, "No notice should be generated for unqueried files")
    }
}
