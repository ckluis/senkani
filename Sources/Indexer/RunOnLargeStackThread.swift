import Foundation

/// Runs a synchronous closure on a fresh `Thread` with a generous stack
/// (default 16 MB) and returns its result.
///
/// Tree-sitter symbol extraction (`*Backend.walk` in
/// `Sources/Indexer/Languages/`) and dependency extraction
/// (`DependencyExtractor.walk`) recurse on AST depth. Real-world Go,
/// TypeScript, and Swift codebases regularly produce ASTs ~200+ deep,
/// and pathological files can go further. Swift Concurrency's
/// cooperative-pool threads have a small (~512 KB) stack — running an
/// `IndexEngine.index` / `IndexEngine.incrementalUpdate` /
/// `IndexEngine.indexFileIncremental` call from a `Task.detached` or an
/// actor-isolated context blows the stack guard with `EXC_BAD_ACCESS`
/// (incident `7C27A798-7748-46C5-9F5B-C6A9325EF58A`, 2026-05-10:
/// `MCPSession.warmIndex` → `IndexEngine.index` → `GoBackend.walk`
/// at `GoBackend.swift:56`, 286 frames deep).
///
/// Entry-point sites that drive AST work (warm-index, file-watcher
/// reindex, `ensureIndex`) MUST wrap their call in this helper so the
/// recursion runs on a Thread sized for real codebases instead of the
/// cooperative pool's small stack.
///
/// **CLI entry-point contract.** Every CLI subcommand that ends up
/// calling `IndexStore.buildOrUpdate` (today: `senkani index`,
/// `senkani bundle`) is `AsyncParsableCommand` and wraps the build
/// in `await runOnLargeStackThread { ... }`. `IndexStore.buildOrUpdate`
/// itself stays synchronous — wrapping happens at the entry sites so
/// the safety contract is symmetric with `MCPSession.ensureIndex`.
/// Don't add new sync CLI paths that call `IndexStore.buildOrUpdate`
/// without this helper.
///
/// 16 MB handles ASTs up to roughly 8000 levels deep at typical Swift
/// frame sizes — well past anything a real source file can produce. If
/// a future bug surfaces a deeper tree, the answer is to fix the
/// recursion (iterative walk or depth cap), not to keep raising the
/// stack.
public func runOnLargeStackThread<T: Sendable>(
    stackSize: Int = 16 * 1024 * 1024,
    _ work: @Sendable @escaping () -> T
) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        let thread = Thread {
            cont.resume(returning: work())
        }
        thread.stackSize = stackSize
        thread.start()
    }
}

/// Throwing variant of `runOnLargeStackThread`.
public func runOnLargeStackThread<T: Sendable>(
    stackSize: Int = 16 * 1024 * 1024,
    _ work: @Sendable @escaping () throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
        let thread = Thread {
            do {
                cont.resume(returning: try work())
            } catch {
                cont.resume(throwing: error)
            }
        }
        thread.stackSize = stackSize
        thread.start()
    }
}
