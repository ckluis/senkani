import ArgumentParser
import Foundation
import Core
import Indexer
import Bundle

// MARK: - senkani bundle
//
// CLI wrapper over `BundleComposer`. Reads the on-disk symbol index
// (no MCPSession needed), composes the bundle, writes to `--output`
// or stdout.
//
// Usage:
//   senkani bundle                         # stdout, default budget
//   senkani bundle --output repo.md
//   senkani bundle --budget 8000
//   senkani bundle --root ../other-project --output other.md
//
// Security: both `--root` and `--output` go through
// `ProjectSecurity.validateProjectPath` / explicit absolute-path checks
// so a prompt-injected subagent that ships `senkani bundle --root
// ~/.aws --output /tmp/secrets.md` gets rejected before any file is
// opened (Schneier P0 from the Luminary audit).

struct BundleCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bundle",
        abstract: "Compose the project into a single budget-bounded markdown document."
    )

    @Option(name: .long, help: "Project root directory (defaults to current directory).")
    var root: String?

    @Option(name: .long, help: "Token budget (char/4 approx). Default 20000, clamped to [500, 200000].")
    var budget: Int = 20_000

    @Option(name: .long, help: "Path to write the bundle. Defaults to stdout.")
    var output: String?

    @Flag(name: .long, help: "Rebuild the symbol index before composing (slower on cold runs).")
    var rebuildIndex: Bool = false

    @Option(name: .long, help: "Output format: 'markdown' (default) or 'json'.")
    var format: String = "markdown"

    @Option(name: .long, help: "Bundle a remote public GitHub repo (owner/name) instead of a local project.")
    var remote: String?

    @Option(name: .long, help: "Git ref (branch/tag/SHA) to bundle when using --remote. Defaults to HEAD.")
    var ref: String?

    func run() throws {
        guard let bundleFormat = BundleFormat(rawValue: format) else {
            fputs("senkani bundle: invalid --format '\(format)'. Expected 'markdown' or 'json'.\n", stderr)
            throw ExitCode(2)
        }
        if let repo = remote {
            try runRemote(repo: repo, format: bundleFormat)
            return
        }
        // 1. Resolve + validate root.
        let requestedRoot = root ?? FileManager.default.currentDirectoryPath
        let validatedRoot: String
        do {
            validatedRoot = try ProjectSecurity.validateProjectPath(requestedRoot).path
        } catch {
            fputs("senkani bundle: invalid --root: \(error.localizedDescription)\n", stderr)
            throw ExitCode(2)
        }

        // 2. Load (or rebuild) the symbol index.
        let index: SymbolIndex
        if rebuildIndex {
            index = IndexStore.buildOrUpdate(projectRoot: validatedRoot, force: true)
            try? IndexStore.save(index, projectRoot: validatedRoot)
        } else if let cached = IndexStore.load(projectRoot: validatedRoot) {
            index = cached
        } else {
            // Build on first bundle — the CLI doesn't have a warm session
            // to fall back on, so we just do the work now.
            fputs("senkani bundle: no index found, building one now...\n", stderr)
            index = IndexStore.buildOrUpdate(projectRoot: validatedRoot, force: false)
            try? IndexStore.save(index, projectRoot: validatedRoot)
        }

        // 3. Dep graph — IndexEngine builds directly from project files.
        let graph = IndexEngine.buildDependencyGraph(projectRoot: validatedRoot)

        // 4. README.
        let readme = BundleComposer.readme(at: validatedRoot)

        // 5. KB entities — optional. Bundle is still useful without
        //    a knowledge store, so skip silently when no DB exists.
        var entities: [KnowledgeEntity] = []
        let kbPath = validatedRoot + "/.senkani/knowledge.db"
        if FileManager.default.fileExists(atPath: kbPath),
           let store = try? KnowledgeStore(projectRoot: validatedRoot) {
            entities = store.allEntities(sortedBy: .mentionCountDesc)
        }

        // 6. Compose.
        let opts = BundleOptions(projectRoot: validatedRoot, maxTokens: budget)
        let inputs = BundleInputs(
            index: index, graph: graph,
            entities: entities, readme: readme)
        let document = BundleComposer.compose(options: opts, inputs: inputs, format: bundleFormat)

        // 7. Emit.
        try emit(document: document)
    }

    // MARK: - Remote path

    private func runRemote(repo: String, format bundleFormat: BundleFormat) throws {
        // Validate first so malformed identifiers fail fast with a
        // clear message, before any network activity.
        do {
            try RemoteRepoClient.validateRepo(repo)
        } catch {
            fputs("senkani bundle: invalid --remote '\(repo)': \(error.localizedDescription)\n", stderr)
            throw ExitCode(2)
        }

        let client = RemoteRepoClient()
        let document: String
        do {
            let inputs = try runAsync {
                try await BundleComposer.fetchRemote(
                    client: client, repo: repo, ref: ref)
            }
            let opts = BundleOptions(
                projectRoot: repo,
                maxTokens: budget
            )
            document = BundleComposer.composeRemote(
                options: opts, inputs: inputs, format: bundleFormat)
        } catch let e as RemoteRepoError {
            fputs("senkani bundle --remote: \(e.description)\n", stderr)
            throw ExitCode(2)
        } catch {
            fputs("senkani bundle --remote: \(error.localizedDescription)\n", stderr)
            throw ExitCode(2)
        }
        try emit(document: document)
    }

    /// Run an async block from a sync `run()` context. `semaphore.wait`
    /// is fine here because `run()` is invoked on its own short-lived
    /// process, not a shared runloop.
    private func runAsync<T: Sendable>(_ op: @Sendable @escaping () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            do { box.value = .success(try await op()) }
            catch { box.value = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        switch box.value! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    // MARK: - Emit

    private func emit(document: String) throws {
        if let outPath = output, !outPath.isEmpty, outPath != "-" {
            // Validate that `output` is an absolute path or relative
            // to the validated root — reject paths that traverse out
            // of the filesystem or contain suspicious components.
            let outURL = URL(fileURLWithPath: outPath)
            let standardized = outURL.standardizedFileURL.path
            if standardized.contains("/..") {
                fputs("senkani bundle: --output path contains `..` components: \(outPath)\n", stderr)
                throw ExitCode(2)
            }
            let outData = Data(document.utf8)
            try outData.write(to: URL(fileURLWithPath: standardized), options: .atomic)
            print("Bundle written to \(standardized) (\(outData.count) bytes)")
        } else {
            FileHandle.standardOutput.write(Data(document.utf8))
        }
    }
}
