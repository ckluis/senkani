import Testing
import Foundation
@testable import Core

@Suite("T.6b — StdoutSink + MacOSLocalSink + NotificationRouter")
struct StdoutMacOSSinkTests {

    // MARK: - StdoutSink wire shape (acceptance #1)

    @Test("StdoutSink emits one canonical JSON line per NotifyEvent variant")
    func stdoutWireShape() throws {
        // notify_done
        let doneLine = try StdoutSink.render(
            .notifyDone(toolName: "Edit", summary: "patched 1 file")
        )
        #expect(doneLine.last == 0x0A, "render must end with newline")
        let done = try parseJSON(doneLine.dropLast()) // drop trailing "\n"
        #expect(done["kind"] == "notify_done")
        #expect(done["tool"] == "Edit")
        #expect(done["summary"] == "patched 1 file")
        #expect(done["ts"] != nil)
        #expect(done["reason"] == nil) // not present for notify_done
        #expect(done["schedule_id"] == nil)

        // notify_failure
        let failLine = try StdoutSink.render(
            .notifyFailure(toolName: "Bash", reason: "operator denied")
        )
        let fail = try parseJSON(failLine.dropLast())
        #expect(fail["kind"] == "notify_failure")
        #expect(fail["tool"] == "Bash")
        #expect(fail["reason"] == "operator denied")
        #expect(fail["summary"] == nil)

        // schedule_end
        let schedLine = try StdoutSink.render(
            .scheduleEnd(scheduleId: "nightly", summary: "done")
        )
        let sched = try parseJSON(schedLine.dropLast())
        #expect(sched["kind"] == "schedule_end")
        #expect(sched["schedule_id"] == "nightly")
        #expect(sched["summary"] == "done")
        #expect(sched["tool"] == nil)
    }

    @Test("StdoutSink writes through the injected writer with serialised access")
    func stdoutWriterRoundTrip() throws {
        let buffer = ConcurrentBuffer()
        let sink = StdoutSink { data in
            buffer.append(data)
        }
        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))
        try sink.notify(.notifyFailure(toolName: "Bash", reason: "denied"))

        let lines = buffer.lines()
        #expect(lines.count == 2)
        let first = try parseJSON(Data(lines[0].utf8))
        let second = try parseJSON(Data(lines[1].utf8))
        #expect(first["kind"] == "notify_done")
        #expect(second["kind"] == "notify_failure")
    }

    // MARK: - MacOSLocalSink (acceptance #2)

    @Test("MacOSLocalSink scheduled the expected banner via the spy bridge")
    func macosSinkRoutesThroughBridge() throws {
        let spy = SpyLocalNotifierBridge()
        let sink = MacOSLocalSink(bridge: spy)

        try sink.notify(.notifyDone(toolName: "Edit", summary: "patched 1 file"))
        try sink.notify(.notifyFailure(toolName: "Bash", reason: "denied"))
        try sink.notify(.scheduleEnd(scheduleId: "morning-brief", summary: "5 items"))

        #expect(spy.posted == [
            .init(title: "Senkani — done", subtitle: "Edit", body: "patched 1 file"),
            .init(title: "Senkani — failed", subtitle: "Bash", body: "denied"),
            .init(title: "Senkani — schedule", subtitle: "morning-brief", body: "5 items"),
        ])
    }

    @Test("NullLocalNotifierBridge is the default and silently drops every post")
    func macosSinkDefaultIsNull() throws {
        // The default bridge is a Null implementation — `notify` returns
        // without throwing and there is no observable side effect. This
        // is the headless-CLI safety net that lets MacOSLocalSink land
        // in Core without forcing an AppKit dependency on every binary.
        let sink = MacOSLocalSink()
        try sink.notify(.notifyDone(toolName: "Edit", summary: "ok"))
        try sink.notify(.notifyFailure(toolName: "Edit", reason: "boom"))
        try sink.notify(.scheduleEnd(scheduleId: "nightly", summary: "done"))
    }

    // MARK: - Fan-out non-blocking contract (acceptance #3)

    @Test("Throwing real sink does not block other real sinks in the fan-out")
    func throwingSinkDoesNotBlockFanout() throws {
        // Two real (not Mock-based) sinks share a fan-out: a MacOSLocalSink
        // whose bridge throws + a StdoutSink that captures into a buffer.
        // The acceptance criterion in T.6b (parent T.6) is that a thrown
        // error from one adapter does NOT propagate or stall the next —
        // round 1 already proved this for MockNotificationSink, round 2
        // proves it for the real sink types.
        struct BoomError: Error {}
        let throwingBridge = SpyLocalNotifierBridge(errorToThrow: BoomError())
        let throwing = MacOSLocalSink(bridge: throwingBridge)

        let buffer = ConcurrentBuffer()
        let stdout = StdoutSink { data in
            buffer.append(data)
        }

        let event = NotifyEvent.notifyFailure(toolName: "Edit", reason: "denied")
        NotificationFanout.deliver(event, to: [throwing, stdout])

        // The throwing bridge was invoked exactly once …
        #expect(throwingBridge.posted.count == 1)
        // … AND the stdout sink still ran, captured the JSON line.
        let lines = buffer.lines()
        #expect(lines.count == 1)
        let parsed = try parseJSON(Data(lines[0].utf8))
        #expect(parsed["kind"] == "notify_failure")
    }

    // MARK: - NotificationRouter (acceptance #4 — every existing test passes
    // is covered by the suite as a whole; this slice verifies the matrix)

    @Test("NotificationRouter filters fan-out by per-sink event subscription")
    func routerFiltersByConfig() {
        let stdoutMock = MockNotificationSink()
        let macosMock = MockNotificationSink()

        let router = NotificationRouter(entries: [
            .init(name: "stdout", sink: stdoutMock, events: [.notifyFailure]),
            .init(name: "macos_local", sink: macosMock, events: [.notifyFailure, .scheduleEnd]),
        ])

        router.deliver(.notifyDone(toolName: "Edit", summary: "ok"))
        router.deliver(.notifyFailure(toolName: "Bash", reason: "denied"))
        router.deliver(.scheduleEnd(scheduleId: "nightly", summary: "done"))

        // stdout subscribed to failures only
        #expect(stdoutMock.delivered.count == 1)
        if case .notifyFailure = stdoutMock.delivered[0] {} else {
            Issue.record("stdout received unexpected event: \(stdoutMock.delivered[0])")
        }
        // macos subscribed to failures + schedule_end (NOT notifyDone)
        #expect(macosMock.delivered.count == 2)
    }

    @Test("NotificationRouter.make resolves config + defaults missing sinks to all events")
    func routerConfigDefaultsToAllEvents() throws {
        let configured = MockNotificationSink()
        let unspecified = MockNotificationSink()
        let configJSON = """
        {
          "sinks": {
            "stdout": { "events": ["notify_failure"] }
          }
        }
        """
        let config = try JSONDecoder().decode(
            NotificationRouter.Config.self,
            from: Data(configJSON.utf8)
        )
        let router = NotificationRouter.make(
            sinks: [
                ("stdout", configured),
                ("macos_local", unspecified), // absent from config — defaults to all
            ],
            config: config
        )

        router.deliver(.notifyDone(toolName: "Edit", summary: "ok"))
        router.deliver(.notifyFailure(toolName: "Bash", reason: "denied"))
        router.deliver(.scheduleEnd(scheduleId: "nightly", summary: "done"))

        // configured: only notify_failure
        #expect(configured.delivered.count == 1)
        // unspecified: defaults to all three variants
        #expect(unspecified.delivered.count == 3)
    }

    @Test("NotificationRouter.loadConfig returns nil on missing file (default-on)")
    func routerMissingConfigIsNil() {
        let path = "/tmp/senkani-router-missing-\(UUID().uuidString).json"
        // No file at this path — should return nil, not throw, not crash.
        #expect(NotificationRouter.loadConfig(from: path) == nil)
    }

    // MARK: - helpers

    private func parseJSON(_ data: Data) throws -> [String: String?] {
        let any = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var out: [String: String?] = [:]
        for (k, v) in any {
            out[k] = v as? String
        }
        return out
    }
}

// MARK: - Local helpers

/// Tiny lock-protected line buffer. Test-only; mirrors the kind of
/// sink-side serialisation a stdout collector would do.
private final class ConcurrentBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let s = String(data: data, encoding: .utf8) ?? ""
        return s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
