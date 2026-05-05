import Testing
import Foundation
@testable import MCPServer

// MARK: - Ring Buffer Tests

@Suite("senkani_watch — Ring Buffer")
struct WatchRingBufferTests {

    private func makeSession() -> MCPSession {
        MCPSession(projectRoot: "/tmp/watch-test-\(UUID().uuidString)")
    }

    @Test func appendAndDrain() async {
        let session = makeSession()
        let event = MCPSession.ChangeEvent(path: "Sources/main.swift", eventType: "modified", timestamp: Date())
        await session.appendChangeEvents([event])

        let result = await session.changesSince(nil, glob: nil)
        #expect(result.count == 1)
        #expect(result.first?.path == "Sources/main.swift")
    }

    @Test func cursorFiltering() async {
        let session = makeSession()
        let t0 = Date()
        let t1 = t0.addingTimeInterval(1)
        let t2 = t0.addingTimeInterval(2)

        await session.appendChangeEvents([
            .init(path: "a.swift", eventType: "modified", timestamp: t0),
            .init(path: "b.swift", eventType: "modified", timestamp: t1),
            .init(path: "c.swift", eventType: "modified", timestamp: t2),
        ])

        let result = await session.changesSince(t1, glob: nil)
        #expect(result.count == 1, "Since t1 should return only t2, got \(result.count)")
        #expect(result.first?.path == "c.swift")
    }

    @Test func globMatchesSourceSwift() async {
        let session = makeSession()
        await session.appendChangeEvents([
            .init(path: "Sources/Core/Foo.swift", eventType: "modified", timestamp: Date()),
            .init(path: "node_modules/bar.js", eventType: "modified", timestamp: Date()),
        ])

        let result = await session.changesSince(nil, glob: "Sources/**/*.swift")
        #expect(result.count == 1)
        #expect(result.first?.path == "Sources/Core/Foo.swift")
    }

    @Test func globExcludesNodeModules() async {
        let session = makeSession()
        await session.appendChangeEvents([
            .init(path: "node_modules/dep/index.js", eventType: "modified", timestamp: Date()),
            .init(path: "src/app.ts", eventType: "modified", timestamp: Date()),
        ])

        let result = await session.changesSince(nil, glob: "src/**")
        #expect(result.count == 1)
        #expect(result.first?.path == "src/app.ts")
    }

    @Test func bufferOverflow() async {
        let session = makeSession()
        let events = (0..<600).map { i in
            MCPSession.ChangeEvent(path: "file\(i).swift", eventType: "modified", timestamp: Date())
        }
        await session.appendChangeEvents(events)

        let result = await session.changesSince(nil, glob: nil)
        #expect(result.count == 500, "Buffer should cap at 500, got \(result.count)")
        #expect(result.first?.path == "file100.swift", "Oldest should be file100 (first 100 dropped)")
    }

    @Test func emptyBuffer() async {
        let session = makeSession()
        let result = await session.changesSince(nil, glob: nil)
        #expect(result.isEmpty)
    }

    @Test func cursorAdvancement() async {
        let session = makeSession()
        let t0 = Date()

        await session.appendChangeEvents([
            .init(path: "a.swift", eventType: "modified", timestamp: t0),
            .init(path: "b.swift", eventType: "modified", timestamp: t0.addingTimeInterval(1)),
            .init(path: "c.swift", eventType: "modified", timestamp: t0.addingTimeInterval(2)),
        ])

        let first = await session.changesSince(nil, glob: nil)
        #expect(first.count == 3)
        let cursor = first.last!.timestamp

        // Add more events
        await session.appendChangeEvents([
            .init(path: "d.swift", eventType: "modified", timestamp: t0.addingTimeInterval(3)),
            .init(path: "e.swift", eventType: "modified", timestamp: t0.addingTimeInterval(4)),
        ])

        let second = await session.changesSince(cursor, glob: nil)
        #expect(second.count == 2, "After cursor, should get only new events, got \(second.count)")
    }

    @Test func concurrentAccess() async {
        let session = makeSession()

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<10 {
                group.addTask {
                    await session.appendChangeEvents([
                        .init(path: "concurrent\(i).swift", eventType: "modified", timestamp: Date())
                    ])
                    _ = await session.changesSince(nil, glob: nil)
                }
            }
        }

        let result = await session.changesSince(nil, glob: nil)
        #expect(result.count == 10, "All 10 concurrent events should be captured")
    }
}
