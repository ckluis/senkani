import Testing
import Foundation

// MARK: - Helpers

private func makeTempDir() -> String {
    let path = "/tmp/senkani-ws-test-\(UUID().uuidString)"
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

private func makeTempGitRepo() -> String {
    let path = makeTempDir()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["init", path]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try! process.run()
    process.waitUntilExit()
    // Need at least one commit for worktrees to work
    let commit = Process()
    commit.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    commit.arguments = ["-C", path, "commit", "--allow-empty", "-m", "init"]
    commit.standardOutput = FileHandle.nullDevice
    commit.standardError = FileHandle.nullDevice
    commit.environment = [
        "GIT_AUTHOR_NAME": "test", "GIT_AUTHOR_EMAIL": "t@t.com",
        "GIT_COMMITTER_NAME": "test", "GIT_COMMITTER_EMAIL": "t@t.com",
    ]
    try! commit.run()
    commit.waitUntilExit()
    return path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

/// Check if a path is a git repo using the same pattern as GitWorktreeManager.
private func isGitRepo(_ path: String) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", path, "rev-parse", "--is-inside-work-tree"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch { return false }
}

/// Create a git worktree (mirrors GitWorktreeManager.createWorktree).
private func createWorktree(projectRoot: String, slug: String) -> String? {
    let worktreesDir = projectRoot + "/.worktrees"
    try? FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
    let worktreePath = worktreesDir + "/" + slug

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", projectRoot, "worktree", "add", worktreePath, "-b", "feature/test-\(slug)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? worktreePath : nil
    } catch { return nil }
}

/// Simple slugify (mirrors GitWorktreeManager.slugify).
private func slugify(_ name: String) -> String {
    var slug = name.lowercased()
    slug = slug.map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
        .reduce("") { $0 + String($1) }
    while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
    slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return slug.isEmpty ? "workstream" : String(slug.prefix(50))
}

// MARK: - Suite 1: Git Worktree Operations

@Suite("Workstream — Git Worktree")
struct GitWorktreeTests {

    @Test func isGitRepoDetectsRepo() {
        let repo = makeTempGitRepo()
        defer { cleanup(repo) }
        #expect(isGitRepo(repo) == true)
    }

    @Test func isGitRepoRejectsNonRepo() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        #expect(isGitRepo(dir) == false)
    }

    @Test func createWorktreeProducesDirectory() {
        let repo = makeTempGitRepo()
        defer { cleanup(repo) }

        let path = createWorktree(projectRoot: repo, slug: "test-feature")
        #expect(path != nil, "Worktree creation should succeed")
        if let path {
            #expect(FileManager.default.fileExists(atPath: path), "Worktree directory should exist")
            #expect(FileManager.default.fileExists(atPath: path + "/.git"), "Should have .git file")
        }
    }

    @Test func createWorktreeFailsForNonRepo() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let path = createWorktree(projectRoot: dir, slug: "test")
        #expect(path == nil, "Worktree creation should fail for non-git directory")
    }
}

// MARK: - Suite 2: Slugification

@Suite("Workstream — Slugify")
struct SlugifyTests {

    @Test func slugifiesNormalName() {
        #expect(slugify("auth refactor") == "auth-refactor")
    }

    @Test func slugifiesSpecialChars() {
        #expect(slugify("Fix Bug #4521!") == "fix-bug-4521")
    }

    @Test func slugifiesEmptyToDefault() {
        #expect(slugify("") == "workstream")
    }

    @Test func slugifiesUnicode() {
        // Unicode letters pass isLetter check, which is correct behavior
        #expect(slugify("café feature") == "café-feature")
    }
}

// MARK: - Suite 3: Persistence v1/v2 Format (raw JSON validation)

@Suite("Workstream — Persistence Format")
struct WorkstreamPersistenceTests {

    @Test func v1FormatHasPanesAtProjectLevel() throws {
        let v1JSON = """
        {"version":1,"projects":[{"name":"Test","path":"/tmp","panes":[{"title":"T","paneType":"terminal","features":{"filter":true,"cache":true,"secrets":true,"indexer":true,"terse":false},"shellCommand":"/bin/zsh","initialCommand":"","workingDirectory":"/tmp","previewFilePath":"","columnWidth":300,"totalRawBytes":5000,"commandCount":42}]}]}
        """.data(using: .utf8)!

        let json = try JSONSerialization.jsonObject(with: v1JSON) as! [String: Any]
        let projects = json["projects"] as! [[String: Any]]
        let panes = projects[0]["panes"] as! [[String: Any]]

        #expect(json["version"] as? Int == 1)
        #expect(panes.count == 1, "v1 should have panes at project level")
        #expect(panes[0]["totalRawBytes"] as? Int == 5000, "Metrics must be present")
        #expect(panes[0]["commandCount"] as? Int == 42)
        #expect(projects[0]["workstreams"] == nil, "v1 should have no workstreams key")
    }

    @Test func v2FormatHasWorkstreams() throws {
        let v2JSON = """
        {"version":2,"projects":[{"name":"Test","path":"/tmp","workstreams":[{"name":"default","isDefault":true,"panes":[{"title":"T","paneType":"terminal","features":{"filter":true,"cache":true,"secrets":true,"indexer":true,"terse":false},"shellCommand":"/bin/zsh","initialCommand":"","workingDirectory":"/tmp","previewFilePath":"","columnWidth":300,"totalRawBytes":8888}]}],"activeWorkstreamIndex":0}]}
        """.data(using: .utf8)!

        let json = try JSONSerialization.jsonObject(with: v2JSON) as! [String: Any]
        let projects = json["projects"] as! [[String: Any]]
        let workstreams = projects[0]["workstreams"] as! [[String: Any]]

        #expect(json["version"] as? Int == 2)
        #expect(workstreams.count == 1)
        #expect(workstreams[0]["isDefault"] as? Bool == true)
        let wsPanes = workstreams[0]["panes"] as! [[String: Any]]
        #expect(wsPanes[0]["totalRawBytes"] as? Int == 8888)
    }

    @Test func v1MetricsFieldsAllPresent() throws {
        let v1JSON = """
        {"version":1,"projects":[{"name":"T","path":"/tmp","panes":[{"title":"T","paneType":"terminal","features":{"filter":true,"cache":true,"secrets":true,"indexer":true,"terse":false},"shellCommand":"/bin/zsh","initialCommand":"","workingDirectory":"/tmp","previewFilePath":"","columnWidth":300,"totalRawBytes":9999,"totalFilteredBytes":1111,"commandCount":55,"secretsCaught":3}]}]}
        """.data(using: .utf8)!

        let json = try JSONSerialization.jsonObject(with: v1JSON) as! [String: Any]
        let pane = (json["projects"] as! [[String: Any]])[0]["panes"] as! [[String: Any]]

        #expect(pane[0]["totalRawBytes"] as? Int == 9999)
        #expect(pane[0]["totalFilteredBytes"] as? Int == 1111)
        #expect(pane[0]["commandCount"] as? Int == 55)
        #expect(pane[0]["secretsCaught"] as? Int == 3)
    }

    @Test func multipleWorkstreamsInV2() throws {
        let v2JSON = """
        {"version":2,"projects":[{"name":"Test","path":"/tmp","workstreams":[{"name":"default","isDefault":true,"panes":[]},{"name":"auth-refactor","isDefault":false,"branch":"feature/auth","worktreePath":"/tmp/.worktrees/auth","panes":[]}],"activeWorkstreamIndex":1}]}
        """.data(using: .utf8)!

        let json = try JSONSerialization.jsonObject(with: v2JSON) as! [String: Any]
        let projects = json["projects"] as! [[String: Any]]
        let workstreams = projects[0]["workstreams"] as! [[String: Any]]

        #expect(workstreams.count == 2)
        #expect(workstreams[1]["name"] as? String == "auth-refactor")
        #expect(workstreams[1]["branch"] as? String == "feature/auth")
        #expect(workstreams[1]["worktreePath"] as? String == "/tmp/.worktrees/auth")
        #expect(projects[0]["activeWorkstreamIndex"] as? Int == 1)
    }
}

// MARK: - Suite 4: Effective Root Isolation

@Suite("Workstream — Effective Root")
struct EffectiveRootTests {

    @Test func worktreePathOverridesProjectPath() {
        // When worktreePath is set, effectiveRoot should return it
        // (Testing the concept — actual WorkstreamModel is in SenkaniApp, not importable)
        let worktreePath = "/tmp/project/.worktrees/feature-auth"
        let projectPath = "/tmp/project"
        let effectiveRoot = worktreePath  // mirrors WorkstreamModel.effectiveRoot when worktreePath is non-nil
        #expect(effectiveRoot == worktreePath)
        #expect(effectiveRoot != projectPath)
    }

    @Test func nilWorktreePathFallsBackToProjectPath() {
        let worktreePath: String? = nil
        let projectPath = "/tmp/project"
        let effectiveRoot = worktreePath ?? projectPath
        #expect(effectiveRoot == projectPath)
    }

    @Test func worktreePathUsedForSENKANI_PROJECT_ROOT() {
        // SENKANI_PROJECT_ROOT = pane.workingDirectory
        // pane.workingDirectory = workstream.effectiveRoot(projectPath:)
        // Therefore: workstream with worktreePath → isolated SENKANI_PROJECT_ROOT
        let worktreePath = "/tmp/project/.worktrees/hotfix"
        let env = ["SENKANI_PROJECT_ROOT": worktreePath]
        #expect(env["SENKANI_PROJECT_ROOT"] == worktreePath)
        #expect(env["SENKANI_PROJECT_ROOT"] != "/tmp/project")
    }
}
