import Testing
import Foundation
@testable import Core

// MARK: - Helpers

private func makeTempDB() -> (SessionDatabase, String) {
    let path = "/tmp/senkani-timeline-test-\(UUID().uuidString).sqlite"
    let db = SessionDatabase(path: path)
    return (db, path)
}

private func cleanup(_ path: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: path)
    try? fm.removeItem(atPath: path + "-wal")
    try? fm.removeItem(atPath: path + "-shm")
}

/// Record a token event and flush the async queue by calling a sync read.
private func recordEvent(
    db: SessionDatabase,
    projectRoot: String?,
    source: String = "mcp",
    toolName: String? = "read",
    feature: String? = "read",
    command: String? = "cat file.swift",
    inputTokens: Int = 100,
    outputTokens: Int = 50,
    savedTokens: Int = 50,
    costCents: Int = 1
) {
    db.recordTokenEvent(
        sessionId: "test-session",
        paneId: nil,
        projectRoot: projectRoot,
        source: source,
        toolName: toolName,
        model: nil,
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        savedTokens: savedTokens,
        costCents: costCents,
        feature: feature,
        command: command
    )
    // Flush: sync read drains prior async writes
    _ = db.tokenStatsAllProjects()
}

@Suite("SessionDatabase — Timeline Events")
struct TimelineEventTests {

    @Test func recentTokenEventsReturnsNewestFirst() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        for i in 0..<5 {
            recordEvent(db: db, projectRoot: "/tmp/test", inputTokens: i * 10)
        }

        let events = db.recentTokenEvents(projectRoot: "/tmp/test", limit: 10)
        #expect(events.count == 5)
        // Newest first — timestamps should be descending
        for i in 0..<(events.count - 1) {
            #expect(events[i].timestamp >= events[i + 1].timestamp)
        }
    }

    @Test func recentTokenEventsRespectsLimit() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        for _ in 0..<50 {
            recordEvent(db: db, projectRoot: "/tmp/test")
        }

        let events = db.recentTokenEvents(projectRoot: "/tmp/test", limit: 20)
        #expect(events.count == 20)
    }

    @Test func recentTokenEventsScopesToProject() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        for _ in 0..<3 {
            recordEvent(db: db, projectRoot: "/tmp/projectA")
        }
        for _ in 0..<3 {
            recordEvent(db: db, projectRoot: "/tmp/projectB")
        }

        let eventsA = db.recentTokenEvents(projectRoot: "/tmp/projectA")
        let eventsB = db.recentTokenEvents(projectRoot: "/tmp/projectB")
        #expect(eventsA.count == 3)
        #expect(eventsB.count == 3)
    }

    @Test func recentTokenEventsAllProjectsReturnsAll() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        for _ in 0..<3 {
            recordEvent(db: db, projectRoot: "/tmp/projectA")
        }
        for _ in 0..<3 {
            recordEvent(db: db, projectRoot: "/tmp/projectB")
        }

        let all = db.recentTokenEventsAllProjects(limit: 100)
        #expect(all.count == 6)
    }

    @Test func timelineEventFieldsPopulated() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        recordEvent(
            db: db,
            projectRoot: "/tmp/test",
            source: "mcp",
            toolName: "exec",
            feature: "exec",
            command: "npm test",
            inputTokens: 200,
            outputTokens: 80,
            savedTokens: 120,
            costCents: 5
        )

        let events = db.recentTokenEvents(projectRoot: "/tmp/test")
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.source == "mcp")
        #expect(e.toolName == "exec")
        #expect(e.feature == "exec")
        #expect(e.command == "npm test")
        #expect(e.inputTokens == 200)
        #expect(e.outputTokens == 80)
        #expect(e.savedTokens == 120)
        #expect(e.costCents == 5)
        #expect(e.id > 0)
    }

    @Test func timelineEventHandlesNullFields() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        recordEvent(
            db: db,
            projectRoot: "/tmp/test",
            source: "hook",
            toolName: nil,
            feature: nil,
            command: nil,
            inputTokens: 0,
            outputTokens: 0,
            savedTokens: 0,
            costCents: 0
        )

        let events = db.recentTokenEvents(projectRoot: "/tmp/test")
        #expect(events.count == 1)
        let e = events[0]
        #expect(e.toolName == nil)
        #expect(e.feature == nil)
        #expect(e.command == nil)
        #expect(e.source == "hook")
    }

    @Test func timelineEventEquatable() {
        let e1 = SessionDatabase.TimelineEvent(
            id: 1, timestamp: Date(timeIntervalSince1970: 1000), source: "mcp",
            toolName: "read", feature: "read", command: "cat file",
            inputTokens: 100, outputTokens: 50, savedTokens: 50, costCents: 1
        )
        let e2 = SessionDatabase.TimelineEvent(
            id: 1, timestamp: Date(timeIntervalSince1970: 1000), source: "mcp",
            toolName: "read", feature: "read", command: "cat file",
            inputTokens: 100, outputTokens: 50, savedTokens: 50, costCents: 1
        )
        let e3 = SessionDatabase.TimelineEvent(
            id: 2, timestamp: Date(timeIntervalSince1970: 1000), source: "mcp",
            toolName: "read", feature: "read", command: "cat file",
            inputTokens: 100, outputTokens: 50, savedTokens: 50, costCents: 1
        )
        #expect(e1 == e2)
        #expect(e1 != e3)
    }

    @Test func recentTokenEventsEmptyProjectReturnsEmpty() {
        let (db, path) = makeTempDB()
        defer { cleanup(path) }

        recordEvent(db: db, projectRoot: "/tmp/projectA")

        let events = db.recentTokenEvents(projectRoot: "/tmp/projectB")
        #expect(events.isEmpty)
    }
}
