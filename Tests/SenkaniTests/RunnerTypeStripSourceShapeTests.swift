import Testing
import Foundation

/// Structural (source-shape) contract for
/// `browserpane-subprocess-runner-node-ts-typeimport-2026-07-07`.
///
/// **Why source-shape.** `PlaywrightSubprocessRunner.spawnAndDecode`
/// spawns the Playwright driver as bare `/usr/bin/env node <runner.ts>`
/// with NO TypeScript loader — it relies on Node's DEFAULT
/// type-stripping (unflagged since Node 22.18 / 23.6). Type-stripping
/// erases type annotations but CANNOT elide a type-only binding that
/// shares a value import: a merged
/// `import { chromium, Browser, Page } from "playwright"` leaves
/// `Browser`/`Page` as runtime value imports, and playwright's ESM entry
/// does not export them as values, so Node throws a hard
/// `SyntaxError: The requested module 'playwright' does not provide an
/// export named 'Browser'` BEFORE `main()` runs. Because
/// `BrowserValidationDispatcher` defaults `dispatch = .subprocess`, that
/// SyntaxError breaks the DEFAULT `senkani validate --browser` path on
/// any modern-Node host.
///
/// The existing runner tests (`PlaywrightRunnerAxisExtractionTests`)
/// parse the extracted axis JS via JavaScriptCore `new Function()` and
/// never spawn `node runner.ts`, so this ESM/type-stripping class of
/// breakage is invisible to them. This suite is the durable CI guard:
/// it reads every `.ts` file Node executes directly under
/// `Resources/playwright-runner/` and asserts none contains the revert
/// pattern — an unmarked type-only specifier (`Browser`/`Page`) inside a
/// VALUE import from `'playwright'`. The runtime proof (a real
/// `dispatch=subprocess` validation against localhost fixtures returning
/// a structured `PlaywrightResult`) is a same-machine walk filed as
/// evidence on the item; this test keeps a future edit from silently
/// re-merging the imports.
@Suite("Playwright runner.ts Node type-strip source-shape contract")
struct RunnerTypeStripSourceShapeTests {

    /// Walk up from CWD to find `Resources/playwright-runner/`.
    private static func runnerDir() -> URL? {
        var cur = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = cur.appendingPathComponent(
                "Resources/playwright-runner", isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = cur.deletingLastPathComponent()
            if parent.path == cur.path { break }
            cur = parent
        }
        return nil
    }

    /// Every `.ts` file under `Resources/playwright-runner/` — these are
    /// the files Node executes directly under default type-stripping.
    /// (The `axes/*.js` siblings are plain JS loaded as strings and
    /// handed to `page.evaluate`; they are not type-stripped, so they are
    /// intentionally excluded.)
    private static func executedTSFiles() -> [URL] {
        guard let dir = runnerDir() else { return [] }
        guard let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in en where url.pathExtension == "ts" {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Returns the offending specifier tokens found in single-line
    /// value imports from `'playwright'` — i.e. bare (un-`type`-prefixed)
    /// type-only names `Browser` / `Page` sitting inside an
    /// `import { ... } from "playwright"` that is NOT an `import type`.
    /// Empty ⇒ the file is type-strippable by bare `node`.
    private static func mixedValueTypeImportViolations(_ source: String) -> [String] {
        let typeOnlyNames: Set<String> = ["Browser", "Page"]
        var violations: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("import ") else { continue }
            let fromPlaywright = line.contains("from \"playwright\"")
                || line.contains("from 'playwright'")
            guard fromPlaywright else { continue }
            // `import type { ... }` erases the whole clause — safe.
            if line.hasPrefix("import type ") { continue }
            guard let open = line.firstIndex(of: "{"),
                  let close = line.firstIndex(of: "}"),
                  open < close else { continue }
            let inner = String(line[line.index(after: open)..<close])
            for spec in inner.split(separator: ",") {
                let token = spec.trimmingCharacters(in: .whitespaces)
                // Inline-marked (`type Browser`) or aliased-out forms are fine.
                if token.hasPrefix("type ") { continue }
                // First identifier of the specifier (handles `Browser as B`).
                let name = token.split(whereSeparator: { $0 == " " || $0 == "\t" })
                    .first.map(String.init) ?? token
                if typeOnlyNames.contains(name) {
                    violations.append(name)
                }
            }
        }
        return violations
    }

    @Test("No executed runner .ts merges a type-only playwright import into a value import (bare `node` type-strippable)")
    func noMixedValueTypeImportFromPlaywright() throws {
        let files = Self.executedTSFiles()
        // Resources/ resolution depends on CWD — skip gracefully when run
        // from outside a checkout (mirrors BrowserPaneRunnerAsyncEvalTests).
        guard !files.isEmpty else { return }

        for url in files {
            let source = try String(contentsOf: url, encoding: .utf8)
            let violations = Self.mixedValueTypeImportViolations(source)
            #expect(violations.isEmpty,
                    "\(url.lastPathComponent) merges type-only name(s) \(violations) into a VALUE `import { ... } from \"playwright\"`. Node's default type-stripping (bare `node runner.ts`, no TS loader) cannot elide a type-only binding that shares a value import, so this throws `SyntaxError: … does not provide an export named 'Browser'` and breaks the DEFAULT `.subprocess` browser-validation dispatch. Split them: `import { chromium } from \"playwright\";` + `import type { Browser, Page } from \"playwright\";` (or inline `type` markers).")
        }
    }

    @Test("runner.ts keeps chromium as a value import and Browser/Page under `import type`")
    func chromiumValueAndTypesImportTypeQualified() throws {
        let files = Self.executedTSFiles()
        guard let runner = files.first(where: { $0.lastPathComponent == "runner.ts" }) else {
            return  // skip gracefully outside a checkout
        }
        let source = try String(contentsOf: runner, encoding: .utf8)

        // `chromium` is a load-bearing RUNTIME value (`chromium.launch()`),
        // so it must remain a value import, not accidentally folded under
        // `import type`.
        #expect(source.contains("import { chromium } from \"playwright\";"),
                "runner.ts must import `chromium` as a runtime VALUE (`import { chromium } from \"playwright\";`) — it calls `chromium.launch()`. Folding it under `import type` would erase it at runtime.")

        // `Browser`/`Page` are used only as type annotations
        // (`let browser: Browser | null`, `page: Page`) and MUST be
        // imported type-only so bare `node` strips them.
        #expect(source.contains("import type { Browser, Page } from \"playwright\";"),
                "runner.ts must import `Browser`/`Page` via a dedicated `import type { Browser, Page } from \"playwright\";` line so Node's default type-stripping erases them — they have no runtime value export in playwright's ESM entry.")
    }
}
