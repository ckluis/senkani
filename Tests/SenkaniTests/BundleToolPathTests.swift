import Testing
import Foundation
import MCP
@testable import Core
@testable import MCPServer

// MARK: - BundleToolPathTests
//
// Bach Phase-6 gap closure: feed `BundleTool.handle` obviously-hostile
// `root` values and assert the MCP result is marked `isError: true`
// with a diagnostic message — not a silently-composed bundle of the
// wrong directory.
//
// `ProjectSecurity.validateProjectPath` has its own unit coverage
// (Bach G1), but this test is the integration gate: proof that the
// tool actually calls the validator and refuses to proceed when
// validation fails.

@Suite("BundleTool path validation (Bach Phase-6)")
struct BundleToolPathTests {

    /// Spin up a throwaway MCPSession pointed at a valid temp project,
    /// then invoke the tool with a hostile override.
    private func makeSession() -> (MCPSession, String) {
        let root = NSTemporaryDirectory() + "senkani-bundle-tool-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        let session = MCPSession(
            projectRoot: root,
            filterEnabled: false,
            secretsEnabled: false,
            indexerEnabled: false,
            cacheEnabled: false
        )
        return (session, root)
    }

    @Test func rejectsPathWithDotDotComponents() async {
        let (session, root) = makeSession()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let args: [String: Value] = [
            "root": .string("../../../etc"),
        ]
        let result = await BundleTool.handle(arguments: args, session: session)
        #expect(result.isError == true,
            "`..` components must trigger path-validation rejection")
        // Expect a diagnostic message, not a composed bundle.
        if case .text(let body, _, _) = result.content.first {
            #expect(body.contains("invalid `root`") || body.contains("invalid"),
                "error text should explain the rejection")
            #expect(!body.contains("## Outlines"),
                "rejected path must not proceed to bundle composition")
        }
    }

    @Test func rejectsPathWithNullByte() async {
        let (session, root) = makeSession()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let args: [String: Value] = [
            "root": .string("/tmp\0/smuggled"),
        ]
        let result = await BundleTool.handle(arguments: args, session: session)
        #expect(result.isError == true)
    }

    @Test func rejectsNonExistentPath() async {
        let (session, root) = makeSession()
        defer { try? FileManager.default.removeItem(atPath: root) }

        let args: [String: Value] = [
            "root": .string("/definitely/does/not/exist/\(UUID().uuidString)"),
        ]
        let result = await BundleTool.handle(arguments: args, session: session)
        #expect(result.isError == true)
    }

    @Test func rejectsPathThatIsAFile() async throws {
        let (session, root) = makeSession()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // Create a regular file; validateProjectPath requires a directory.
        let filePath = root + "/some-file.txt"
        try "hi".write(toFile: filePath, atomically: true, encoding: .utf8)

        let args: [String: Value] = [
            "root": .string(filePath),
        ]
        let result = await BundleTool.handle(arguments: args, session: session)
        #expect(result.isError == true)
    }

    @Test func emptyRootFallsBackToSessionRoot() async {
        let (session, root) = makeSession()
        defer { try? FileManager.default.removeItem(atPath: root) }

        // No root arg → session's projectRoot should be used. The
        // index isn't ready in this session, so we expect a "still
        // warming" message, NOT an `isError`. That proves the tool
        // proceeded past the validation gate with the session root.
        let result = await BundleTool.handle(arguments: nil, session: session)
        if case .text(let body, _, _) = result.content.first {
            #expect(body.contains("warming") || body.contains("index"),
                "without a warm index the tool should report that, not an 'invalid root' error")
        }
    }
}
