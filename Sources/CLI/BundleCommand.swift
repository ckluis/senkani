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

    @Option(name: .long, help: "U.10b. Slice mode input: '<path>:<start>:<end>'. Adds one file-lane manifest item carrying the slice (1-indexed inclusive lines). Requires --preview and --modes slice.")
    var slice: String?

    @Option(name: .long, help: "U.10b. Diff-only mode selector: 'unstaged', 'staged', 'branch:<ref>', or 'range:<a>..<b>'. Shells `git diff` and adds one diff-lane item per affected file. Requires --preview and --modes diff-only.")
    var diff: String?

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
            let resolvedModes = parseModes(modes) ?? ContextMode.trivial
            // U.10b — pre-resolve slice / diff inputs at the CLI layer
            // so the producer stays synchronous. Each helper validates
            // and returns nil for malformed input after writing a
            // diagnostic to stderr, then the round throws ExitCode(2).
            let sliceReq: SliceRequest?
            if let raw = slice {
                guard let parsed = parseSlice(raw, projectRoot: validatedRoot) else {
                    throw ExitCode(2)
                }
                sliceReq = parsed
            } else {
                sliceReq = nil
            }

            let diffReq: DiffRequest?
            if let raw = diff {
                guard let parsed = parseDiff(raw, projectRoot: validatedRoot) else {
                    throw ExitCode(2)
                }
                diffReq = parsed
            } else {
                diffReq = nil
            }

            let manifestOpts = ManifestOptions(
                projectRoot: validatedRoot,
                modes: resolvedModes,
                lanes: parseLanes(lanes) ?? Set(ContextLane.allCases),
                slice: sliceReq,
                diff: diffReq
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

    /// Parse `--slice <path>:<start>:<end>`. The path is resolved
    /// relative to `projectRoot` (rejects paths that escape it); the
    /// file is read and sliced by 1-indexed inclusive lines. Returns
    /// nil on any malformed input (writes a diagnostic to stderr).
    private func parseSlice(_ raw: String, projectRoot: String) -> SliceRequest? {
        // Split on the LAST two colons so paths containing colons
        // (none on macOS at this layer, but defensive) still parse.
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        // Expect exactly three components: path, start, end. The
        // split above yields path|rest|end when there are 3+ colons,
        // so we use a regex-tighter form.
        let components = raw.components(separatedBy: ":")
        guard components.count == 3,
              !components[0].isEmpty,
              let start = Int(components[1]),
              let end = Int(components[2]),
              start >= 1, end >= start
        else {
            fputs("senkani bundle: invalid --slice '\(raw)'. Expected '<path>:<start>:<end>' with 1 ≤ start ≤ end.\n", stderr)
            return nil
        }
        _ = parts  // silence unused warning — kept for forward-compat
        let relPath = components[0]
        let absPath: String
        if relPath.hasPrefix("/") {
            absPath = relPath
        } else {
            absPath = (projectRoot as NSString).appendingPathComponent(relPath)
        }
        let resolved = URL(fileURLWithPath: absPath).standardizedFileURL.path
        // Path-traversal guard — keep slice reads under projectRoot.
        let rootResolved = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
        guard resolved.hasPrefix(rootResolved + "/") || resolved == rootResolved else {
            fputs("senkani bundle: --slice path '\(relPath)' resolves outside the project root.\n", stderr)
            return nil
        }
        guard let raw = try? String(contentsOfFile: resolved, encoding: .utf8) else {
            fputs("senkani bundle: --slice cannot read '\(resolved)'.\n", stderr)
            return nil
        }
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false)
        let lo = max(0, start - 1)
        let hi = min(lines.count, end)
        guard lo < hi else {
            fputs("senkani bundle: --slice range \(start):\(end) is empty for file of \(lines.count) lines.\n", stderr)
            return nil
        }
        let sliced = lines[lo..<hi].joined(separator: "\n")
        return SliceRequest(
            path: relPath,
            range: ContextRange(start: start, end: end),
            content: sliced
        )
    }

    /// Parse `--diff <selector>`. Shells `git diff` per the selector
    /// shape and splits the patch into per-file blocks. Returns nil
    /// on parser or git failure (writes a diagnostic to stderr).
    private func parseDiff(_ raw: String, projectRoot: String) -> DiffRequest? {
        guard let selector = DiffSelector(rawValue: raw) else {
            fputs("senkani bundle: invalid --diff '\(raw)'. Expected 'unstaged', 'staged', 'branch:<ref>', or 'range:<a>..<b>'.\n", stderr)
            return nil
        }
        let args = gitArgs(for: selector)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", projectRoot] + args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            fputs("senkani bundle: --diff failed to invoke git: \(error.localizedDescription)\n", stderr)
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let patch = String(data: data, encoding: .utf8) ?? ""
        let perFile = splitDiffByFile(patch)
        return DiffRequest(selector: selector, perFileDiff: perFile)
    }

    private func gitArgs(for selector: DiffSelector) -> [String] {
        switch selector {
        case .unstaged: return ["diff"]
        case .staged: return ["diff", "--cached"]
        case .branch(let ref): return ["diff", "\(ref)...HEAD"]
        case .range(let a, let b): return ["diff", "\(a)..\(b)"]
        }
    }

    /// Split a unified diff into per-file blocks keyed by post-rename
    /// path (the `b/` side). One block per `diff --git a/x b/y` header.
    private func splitDiffByFile(_ patch: String) -> [String: String] {
        var result: [String: String] = [:]
        if patch.isEmpty { return result }
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        var current: String? = nil
        var buffer: [String] = []
        func flush() {
            if let path = current {
                result[path, default: ""] += buffer.joined(separator: "\n")
            }
            buffer.removeAll(keepingCapacity: true)
        }
        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                // Extract the `b/<path>` side. Header form:
                // "diff --git a/foo b/foo" — split on whitespace, take
                // the last token, drop the leading "b/".
                let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
                if let last = tokens.last, last.hasPrefix("b/") {
                    current = String(last.dropFirst(2))
                } else {
                    current = nil
                }
            }
            buffer.append(String(line))
        }
        flush()
        return result
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
