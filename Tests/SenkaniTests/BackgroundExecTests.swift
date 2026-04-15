import Testing
import Foundation
@testable import MCPServer
@testable import Core

// MARK: - Background Exec Tests

@Suite("senkani_exec — Background Mode")
struct BackgroundExecTests {

    private func makeSession() -> MCPSession {
        MCPSession(projectRoot: "/tmp/bg-exec-test-\(UUID().uuidString)")
    }

    @Test func backgroundJobRegistration() {
        let session = makeSession()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.1"]
        try? process.run()

        let job = MCPSession.BackgroundJob(id: "j_test1", process: process, command: "sleep 0.1")
        session.registerBackgroundJob(job)

        let fetched = session.backgroundJob(id: "j_test1")
        #expect(fetched != nil, "Job should be registered")
        #expect(fetched?.command == "sleep 0.1")

        process.waitUntilExit()
    }

    @Test func unknownJobIdReturnsNil() {
        let session = makeSession()
        let result = session.backgroundJob(id: "j_nonexistent")
        #expect(result == nil, "Unknown job should return nil")
    }

    @Test func jobOutputAccumulates() {
        let job = MCPSession.BackgroundJob(
            id: "j_output",
            process: Process(),
            command: "test"
        )

        job.appendOutput(Data("hello ".utf8))
        job.appendOutput(Data("world".utf8))

        #expect(job.output == "hello world")
    }

    @Test func jobOutputCappedAt1MB() {
        let job = MCPSession.BackgroundJob(
            id: "j_cap",
            process: Process(),
            command: "test"
        )

        // Write 2MB of data
        let chunk = Data(repeating: 65, count: 1024 * 1024)  // 1MB of 'A'
        job.appendOutput(chunk)
        job.appendOutput(chunk)  // second MB should be ignored

        #expect(job.output.utf8.count == 1_048_576, "Output should be capped at 1MB")
    }

    @Test func jobExitCodeTracked() {
        let job = MCPSession.BackgroundJob(
            id: "j_exit",
            process: Process(),
            command: "test"
        )

        #expect(job.exitCode == nil, "Should be nil while running")

        job.setExitCode(42)
        #expect(job.exitCode == 42, "Should track exit code")
    }

    @Test func jobKillMarked() {
        let job = MCPSession.BackgroundJob(
            id: "j_kill",
            process: Process(),
            command: "test"
        )

        #expect(job.killed == false)
        job.markKilled()
        #expect(job.killed == true)
    }

    @Test func multipleJobsTrackedIndependently() {
        let session = makeSession()

        let job1 = MCPSession.BackgroundJob(id: "j_1", process: Process(), command: "cmd1")
        let job2 = MCPSession.BackgroundJob(id: "j_2", process: Process(), command: "cmd2")
        let job3 = MCPSession.BackgroundJob(id: "j_3", process: Process(), command: "cmd3")

        session.registerBackgroundJob(job1)
        session.registerBackgroundJob(job2)
        session.registerBackgroundJob(job3)

        #expect(session.backgroundJob(id: "j_1")?.command == "cmd1")
        #expect(session.backgroundJob(id: "j_2")?.command == "cmd2")
        #expect(session.backgroundJob(id: "j_3")?.command == "cmd3")
    }

    @Test func removeJobCleansUp() {
        let session = makeSession()
        let job = MCPSession.BackgroundJob(id: "j_rm", process: Process(), command: "test")
        session.registerBackgroundJob(job)

        #expect(session.backgroundJob(id: "j_rm") != nil)
        session.removeBackgroundJob(id: "j_rm")
        #expect(session.backgroundJob(id: "j_rm") == nil)
    }
}
