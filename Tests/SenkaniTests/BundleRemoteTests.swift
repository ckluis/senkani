import Testing
import Foundation
@testable import Core
@testable import Bundle

// MARK: - Fixtures

private let fixedDate = Date(timeIntervalSince1970: 1_713_360_000)  // 2024-04-17T12:00:00Z

private func makeRemoteClient(token: String? = nil) -> RemoteRepoClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: config)
    return RemoteRepoClient(session: session, token: token)
}

private func registerTreeStub(repo: String, ref: String = "HEAD", body: String) {
    let url = URL(string: "https://api.github.com/repos/\(repo)/git/trees/\(ref)?recursive=1")!
    MockURLProtocol.register(url: url, body: Data(body.utf8))
}

private func registerReadmeRawStub(
    repo: String,
    ref: String = "HEAD",
    filename: String = "README.md",
    body: String
) {
    let url = URL(string: "https://raw.githubusercontent.com/\(repo)/\(ref)/\(filename)")!
    MockURLProtocol.register(url: url, body: Data(body.utf8))
}

private let sampleTreeJSON = #"""
{
  "sha": "abc",
  "url": "https://api.github.com/repos/owner/name/git/trees/abc",
  "tree": [
    {"path": "README.md", "type": "blob"},
    {"path": "Sources", "type": "tree"},
    {"path": "Sources/Main.swift", "type": "blob"},
    {"path": "Sources/Helper.swift", "type": "blob"},
    {"path": "Tests", "type": "tree"},
    {"path": "Tests/MainTests.swift", "type": "blob"}
  ],
  "truncated": false
}
"""#

// MARK: - parseTree

@Suite("BundleComposer.parseTree")
struct BundleComposerParseTreeTests {

    @Test func extractsBlobPathsAndSkipsTrees() throws {
        let (files, truncated) = try BundleComposer.parseTree(body: sampleTreeJSON)
        #expect(files == [
            "README.md",
            "Sources/Helper.swift",
            "Sources/Main.swift",
            "Tests/MainTests.swift",
        ])
        #expect(!truncated)
    }

    @Test func surfacesTruncatedFlag() throws {
        let body = #"{"tree":[{"path":"a","type":"blob"}],"truncated":true}"#
        let (files, truncated) = try BundleComposer.parseTree(body: body)
        #expect(files == ["a"])
        #expect(truncated)
    }

    @Test func rejectsMalformedJSON() {
        #expect(throws: BundleComposer.RemoteBundleError.self) {
            _ = try BundleComposer.parseTree(body: "{not json")
        }
    }

    @Test func rejectsMissingTreeArray() {
        #expect(throws: BundleComposer.RemoteBundleError.self) {
            _ = try BundleComposer.parseTree(body: #"{"sha":"x"}"#)
        }
    }

    @Test func emptyTreeIsOK() throws {
        let (files, truncated) = try BundleComposer.parseTree(
            body: #"{"tree":[],"truncated":false}"#)
        #expect(files.isEmpty)
        #expect(!truncated)
    }
}

// MARK: - URLProtocol-driven tests (fetchRemote + end-to-end)
//
// MockURLProtocol's `stubs` dictionary is process-global, so ALL tests
// that touch it must live in a single `.serialized` suite. Splitting
// into multiple suites lets Swift Testing run them in parallel and
// whichever test happens to call `reset()` between register and fetch
// wipes the sibling's stubs — the same bear-trap RepoNetworkPathTests
// already documented above (see RemoteRepoClientTests.swift).

@Suite("Bundle remote — URLProtocol paths", .serialized)
struct BundleRemoteURLProtocolTests {

    @Test func fetchesTreeAndReadme() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        registerTreeStub(repo: "owner/name", body: sampleTreeJSON)
        registerReadmeRawStub(repo: "owner/name",
                              body: "# Owner/Name\n\nProject README.\n")
        let client = makeRemoteClient()
        let inputs = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name", now: fixedDate)
        #expect(inputs.repo == "owner/name")
        #expect(inputs.files.count == 4)
        #expect(inputs.files.contains("Sources/Main.swift"))
        #expect(inputs.readme?.contains("Project README") == true)
        #expect(!inputs.treeTruncated)
    }

    @Test func readmeAbsentSwallowsNotFound() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        registerTreeStub(repo: "owner/name", body: sampleTreeJSON)
        // No README stub registered → MockURLProtocol returns 404,
        // which the client maps to RemoteRepoError.notFound, which
        // fetchRemote swallows.
        let client = makeRemoteClient()
        let inputs = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name")
        #expect(inputs.readme == nil)
        #expect(inputs.files.count == 4)
    }

    @Test func treeRateLimitPropagates() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let url = URL(string: "https://api.github.com/repos/owner/name/git/trees/HEAD?recursive=1")!
        MockURLProtocol.register(
            url: url, status: 403,
            body: Data(#"{"message":"rate limited"}"#.utf8),
            headers: ["X-RateLimit-Remaining": "0",
                      "X-RateLimit-Reset": "1713360000"]
        )
        let client = makeRemoteClient()
        do {
            _ = try await BundleComposer.fetchRemote(
                client: client, repo: "owner/name")
            Issue.record("expected rateLimited")
        } catch let e as RemoteRepoError {
            if case .rateLimited = e { return }
            Issue.record("expected rateLimited, got \(e)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func treeNotFoundPropagates() async {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        // No stub — MockURLProtocol's fall-through path returns 404.
        let client = makeRemoteClient()
        do {
            _ = try await BundleComposer.fetchRemote(
                client: client, repo: "owner/missing")
            Issue.record("expected notFound")
        } catch let e as RemoteRepoError {
            if case .notFound = e { return }
            Issue.record("expected notFound, got \(e)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func refThreadsThroughToTreeURL() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        registerTreeStub(repo: "owner/name", ref: "v1.2.3",
                         body: #"{"tree":[],"truncated":false}"#)
        let client = makeRemoteClient()
        _ = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name", ref: "v1.2.3")
        let path = MockURLProtocol.lastRequest?.url?.path
        #expect(path?.contains("/git/trees/v1.2.3") == true,
                "ref must appear in the request URL")
    }

    // MARK: End-to-end

    @Test func fetchThenComposeYieldsUsableBundle() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        registerTreeStub(repo: "owner/name", body: sampleTreeJSON)
        registerReadmeRawStub(repo: "owner/name",
                              body: "# owner/name\n\nHello remote.\n")
        let client = makeRemoteClient()
        let inputs = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name", now: fixedDate)
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 20_000, now: fixedDate)
        let md = BundleComposer.composeRemote(options: opts, inputs: inputs)
        #expect(md.contains("# owner/name"))
        #expect(md.contains("`Sources/Main.swift`"))
        #expect(md.contains("Hello remote"))
        #expect(md.contains("## Stats"))
    }

    @Test func secretsInReadmeAreRedactedViaClient() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let key = "sk-ant-api03-" + String(repeating: "Z", count: 85)
        registerTreeStub(repo: "owner/name",
                         body: #"{"tree":[{"path":"a","type":"blob"}],"truncated":false}"#)
        registerReadmeRawStub(repo: "owner/name",
                              body: "leaked: \(key) oh no")
        let client = makeRemoteClient()
        let inputs = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name")
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 20_000, now: fixedDate)
        let md = BundleComposer.composeRemote(options: opts, inputs: inputs)
        #expect(!md.contains(key),
                "SecretDetector on the client path must strip the key before it reaches the bundle")
    }

    @Test func filesSortedDeterministicallyAcrossRuns() async throws {
        MockURLProtocol.reset(); defer { MockURLProtocol.reset() }
        let body = #"""
        {
          "tree": [
            {"path": "z.swift", "type": "blob"},
            {"path": "a.swift", "type": "blob"},
            {"path": "m.swift", "type": "blob"}
          ],
          "truncated": false
        }
        """#
        registerTreeStub(repo: "owner/name", body: body)
        let client = makeRemoteClient()
        let inputs = try await BundleComposer.fetchRemote(
            client: client, repo: "owner/name")
        #expect(inputs.files == ["a.swift", "m.swift", "z.swift"])
    }
}

// MARK: - composeRemote markdown

@Suite("BundleComposer.composeRemote — markdown")
struct BundleComposerRemoteMarkdownTests {

    private func sampleInputs(readme: String? = "# Hello\n\nRemote readme.\n",
                              truncated: Bool = false) -> RemoteBundleInputs {
        RemoteBundleInputs(
            repo: "owner/name", ref: nil,
            files: ["Sources/Main.swift", "Sources/Lib.swift", "README.md"],
            readme: readme,
            generated: fixedDate,
            treeTruncated: truncated
        )
    }

    @Test func headerNamesRemoteRepo() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs())
        #expect(out.contains("# owner/name"))
        #expect(out.contains("remote GitHub snapshot"))
    }

    @Test func outlinesListFilesNoSymbols() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs())
        #expect(out.contains("## Outlines"))
        #expect(out.contains("`Sources/Main.swift`"))
        #expect(out.contains("`Sources/Lib.swift`"))
        // No symbols rendered — remote snapshots don't parse.
        #expect(!out.contains("`function"))
    }

    @Test func emptyDepsAndKBPlaceholders() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs())
        #expect(out.contains("## Dependency Highlights"))
        #expect(out.contains("no dependency graph"))
        #expect(out.contains("## Knowledge Base"))
        #expect(out.contains("no knowledge base"))
    }

    @Test func readmeRenderedWhenPresent() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs())
        #expect(out.contains("## README"))
        #expect(out.contains("Remote readme"))
    }

    @Test func missingReadmeHasPlaceholder() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs(readme: nil))
        #expect(out.contains("no README discovered in remote repo"))
    }

    @Test func treeTruncatedNoticeAppearsInHeader() {
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let out = BundleComposer.composeRemote(
            options: opts, inputs: sampleInputs(truncated: true))
        #expect(out.contains("GitHub flagged the tree response as truncated"))
    }

    @Test func tinyBudgetTruncatesAtSection() {
        // 500 tokens = 2000 chars. Sample inputs' readme + outlines
        // will overflow so we should see the truncation marker.
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 500, now: fixedDate)
        let manyFiles = (0..<500).map { "Sources/File\($0).swift" }
        let inputs = RemoteBundleInputs(
            repo: "owner/name", files: manyFiles,
            readme: String(repeating: "x", count: 5000),
            generated: fixedDate
        )
        let out = BundleComposer.composeRemote(options: opts, inputs: inputs)
        #expect(out.contains("Bundle truncated at"))
    }
}

// MARK: - composeRemote JSON

@Suite("BundleComposer.composeRemote — JSON")
struct BundleComposerRemoteJSONTests {

    @Test func jsonRoundTripsStableSchema() throws {
        let inputs = RemoteBundleInputs(
            repo: "owner/name", ref: "main",
            files: ["a.swift", "b.swift"],
            readme: "# Hello\n",
            generated: fixedDate
        )
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 10_000, now: fixedDate)
        let json = BundleComposer.composeRemote(
            options: opts, inputs: inputs, format: .json)
        let data = Data(json.utf8)
        let doc = try JSONDecoder().decode(BundleDocument.self, from: data)

        #expect(doc.header.projectName == "owner/name@main")
        #expect(doc.header.provenance.contains("(remote)"))
        #expect(doc.stats.filesIndexed == 2)
        #expect(doc.stats.symbols == 0)
        #expect(doc.stats.importEdges == 0)
        #expect(doc.stats.kbEntities == 0)
        #expect(doc.outlines?.files.count == 2)
        #expect(doc.outlines?.files.first?.symbols.isEmpty == true)
        #expect(doc.deps?.topImportedBy.isEmpty == true)
        #expect(doc.kb?.entities.isEmpty == true)
        #expect(doc.readme?.content.contains("Hello") == true)
        #expect(doc.truncated == nil)
    }

    @Test func jsonTruncationBlockOnOverflow() throws {
        let manyFiles = (0..<2000).map { "f\($0).swift" }
        let inputs = RemoteBundleInputs(
            repo: "owner/name",
            files: manyFiles,
            readme: nil,
            generated: fixedDate
        )
        let opts = BundleOptions(projectRoot: "owner/name",
                                 maxTokens: 500, now: fixedDate)
        let json = BundleComposer.composeRemote(
            options: opts, inputs: inputs, format: .json)
        let doc = try JSONDecoder().decode(
            BundleDocument.self, from: Data(json.utf8))
        #expect(doc.truncated != nil,
                "overflow must set `truncated` block in JSON variant")
    }
}

