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

struct BundleCommand: AsyncParsableCommand {
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

    @Flag(name: .long, help: "Emit a ContextManifest review surface (JSON) instead of the bundle body. See U.10a.")
    var preview: Bool = false

    @Option(name: .long, help: "Comma-separated mode list for --preview. Default: full,codemap,artifact-stubbed,excluded-with-reason.")
    var modes: String?

    @Option(name: .long, help: "Comma-separated lane list for --preview. Default: file,diff,codemap,symbol,knowledge,runtime,manual,artifact.")
    var lanes: String?

    @Flag(name: .long, help: "Override the U.10a-2 secret gate. Required when any manifest item carries a SecretDetector hit (sensitivity=flagged). Every override fires a chained bundle.secret.allow audit row in token_events.")
    var allowSecrets: Bool = false

    func run() async throws {
        guard let bundleFormat = BundleFormat(rawValue: format) else {
            fputs("senkani bundle: invalid --format '\(format)'. Expected 'markdown' or 'json'.\n", stderr)
            throw ExitCode(2)
        }
        if let repo = remote {
            try await runRemote(repo: repo, format: bundleFormat)
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
        //
        // AST walks (tree-sitter backends + DependencyExtractor) recurse
        // on AST depth — the build runs on a large-stack background
        // Thread for stack-guard symmetry with `MCPSession.ensureIndex`.
        // See `RunOnLargeStackThread.swift`.
        let index: SymbolIndex
        if rebuildIndex {
            index = await runOnLargeStackThread {
                IndexStore.buildOrUpdate(projectRoot: validatedRoot, force: true)
            }
            try? IndexStore.save(index, projectRoot: validatedRoot)
        } else if let cached = IndexStore.load(projectRoot: validatedRoot) {
            index = cached
        } else {
            // Build on first bundle — the CLI doesn't have a warm session
            // to fall back on, so we just do the work now.
            fputs("senkani bundle: no index found, building one now...\n", stderr)
            index = await runOnLargeStackThread {
                IndexStore.buildOrUpdate(projectRoot: validatedRoot, force: false)
            }
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
        if FileManager.default.fileExists(atPath: kbPath) {
            let store = KnowledgeStore(projectRoot: validatedRoot)
            entities = store.allEntities(sortedBy: .mentionCountDesc)
        }

        // 6. Compose — preview path emits the manifest surface only.
        let inputs = BundleInputs(
            index: index, graph: graph,
            entities: entities, readme: readme)

        if preview {
            let manifestOpts = ManifestOptions(
                projectRoot: validatedRoot,
                modes: parseModes(modes) ?? ContextMode.trivial,
                lanes: parseLanes(lanes) ?? Set(ContextLane.allCases)
            )
            do {
                let manifest = try BundleComposer.composeManifestGated(
                    options: manifestOpts,
                    inputs: inputs,
                    allowSecrets: allowSecrets,
                    preview: true,
                    recorder: LiveBundleAuditRecorder(),
                    sessionId: nil,
                    projectRoot: validatedRoot
                )
                try emit(document: BundleComposer.renderManifestJSON(manifest))
            } catch let e as ManifestSecretGateError {
                fputs("senkani bundle: \(e.description)\n", stderr)
                throw ExitCode(3)
            }
            return
        }

        let opts = BundleOptions(projectRoot: validatedRoot, maxTokens: budget)
        let document = BundleComposer.compose(options: opts, inputs: inputs, format: bundleFormat)

        // 7. Emit.
        try emit(document: document)
    }

    /// Parse a comma-separated `--modes` value. Unknown entries are
    /// silently dropped (matches the MCP tool's `include` parsing).
    /// Returns nil for empty input so callers fall back to the default.
    private func parseModes(_ raw: String?) -> Set<ContextMode>? {
        guard let raw, !raw.isEmpty else { return nil }
        let parsed = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { ContextMode(rawValue: $0) }
        return parsed.isEmpty ? nil : Set(parsed)
    }

    private func parseLanes(_ raw: String?) -> Set<ContextLane>? {
        guard let raw, !raw.isEmpty else { return nil }
        let parsed = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { ContextLane(rawValue: $0) }
        return parsed.isEmpty ? nil : Set(parsed)
    }

    // MARK: - Remote path

    private func runRemote(repo: String, format bundleFormat: BundleFormat) async throws {
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
            let inputs = try await BundleComposer.fetchRemote(
                client: client, repo: repo, ref: ref)
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
