import Testing
import Foundation
@testable import Core
@testable import MCPServer

@Suite("ChangeSetMiner")
struct ChangeSetMinerTests {

    // 1. parseLog with no matching entities → empty commits
    @Test func testParseLogNoMatches() {
        let log = """
        commit abc123

        Sources/Unknown.swift

        """
        let result = ChangeSetMiner.parseLog(log, pathIndex: [:])
        #expect(result.isEmpty)
    }

    // 2. parseLog maps file paths to entity names via pathIndex
    @Test func testParseLogMapsEntitiesToCommits() {
        let index = ["Sources/Foo.swift": ["Foo"], "Sources/Bar.swift": ["Bar"]]
        let log = """
        commit abc123

        Sources/Foo.swift
        Sources/Bar.swift

        commit def456

        Sources/Foo.swift

        """
        let commits = ChangeSetMiner.parseLog(log, pathIndex: index)
        #expect(commits.count == 2)
        #expect(commits[0].contains("Foo") && commits[0].contains("Bar"))
        #expect(commits[1] == ["Foo"])
    }

    // 3. buildPathIndex strips absolute prefix
    @Test func testBuildPathIndexStripsAbsolutePrefix() {
        let root = "/Users/dev/project"
        let entity = KnowledgeEntity(
            name: "MyClass", entityType: "class",
            sourcePath: "/Users/dev/project/Sources/MyClass.swift",
            markdownPath: ".senkani/knowledge/MyClass.md"
        )
        let index = ChangeSetMiner.buildPathIndex([entity], projectRoot: root)
        #expect(index["Sources/MyClass.swift"] == ["MyClass"])
        #expect(index["/Users/dev/project/Sources/MyClass.swift"] == nil)
    }

    // 4. buildPathIndex preserves relative paths unchanged
    @Test func testBuildPathIndexKeepsRelativePaths() {
        let entity = KnowledgeEntity(
            name: "Widget", entityType: "struct",
            sourcePath: "Sources/Widget.swift",
            markdownPath: ".senkani/knowledge/Widget.md"
        )
        let index = ChangeSetMiner.buildPathIndex([entity], projectRoot: "/any/root")
        #expect(index["Sources/Widget.swift"] == ["Widget"])
    }

    // 5. Integration: mine() on a real git repo produces coupling
    @Test func testMineOnRealGitRepo() {
        let root = "/tmp/senkani-miner-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }

        func sh(_ cmd: String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", cmd]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }

        // Init repo
        sh("mkdir -p '\(root)/Sources'")
        sh("git -C '\(root)' init -b main")
        sh("git -C '\(root)' config user.email t@t.com")
        sh("git -C '\(root)' config user.name T")

        // Commit 1: EntityA + EntityB co-change
        sh("echo 'class A {}' > '\(root)/Sources/EntityA.swift'")
        sh("echo 'class B {}' > '\(root)/Sources/EntityB.swift'")
        sh("git -C '\(root)' add . && git -C '\(root)' commit -m 'add A and B'")

        // Commit 2: EntityA + EntityB co-change again
        sh("echo 'class A2 {}' > '\(root)/Sources/EntityA.swift'")
        sh("echo 'class B2 {}' > '\(root)/Sources/EntityB.swift'")
        sh("git -C '\(root)' add . && git -C '\(root)' commit -m 'update A and B'")

        // Commit 3: Only EntityA (solo change)
        sh("echo 'class A3 {}' > '\(root)/Sources/EntityA.swift'")
        sh("git -C '\(root)' add . && git -C '\(root)' commit -m 'update A only'")

        // Insert entities with matching sourcePaths
        let store = KnowledgeStore(projectRoot: root)
        _ = store.upsertEntity(KnowledgeEntity(
            name: "EntityA", entityType: "class",
            sourcePath: "Sources/EntityA.swift",
            markdownPath: ".senkani/knowledge/EntityA.md"
        ))
        _ = store.upsertEntity(KnowledgeEntity(
            name: "EntityB", entityType: "class",
            sourcePath: "Sources/EntityB.swift",
            markdownPath: ".senkani/knowledge/EntityB.md"
        ))

        // Mine
        let (pairs, commits) = ChangeSetMiner.mine(projectRoot: root, store: store)
        #expect(commits == 3, "3 commits analyzed")
        #expect(pairs == 1, "1 coupling pair: EntityA–EntityB")

        // Verify via store query
        let couplings = store.couplings(forEntityName: "EntityA", minScore: 0.0)
        #expect(couplings.count == 1)
        #expect(couplings[0].commitCount == 2)
        #expect(couplings[0].totalCommits == 3)
        #expect(abs(couplings[0].couplingScore - 2.0/3.0) < 0.01)
    }

    // 6. mine() returns (0,0) for non-git directory
    @Test func testMineNonGitDirReturnsZero() {
        let root = "/tmp/senkani-nongit-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = KnowledgeStore(projectRoot: root)
        let (pairs, commits) = ChangeSetMiner.mine(projectRoot: root, store: store)
        #expect(pairs == 0 && commits == 0)
    }
}
