import Foundation
import ArgumentParser
import BrowserPane

// process-gap-browserpane-exerciser-library-carve-2026-06-06 — the
// autonomous carve of the BrowserPane direct-API exerciser.
//
// This executable drives `BrowserPane.BrowserPaneRunner`'s public API
// directly (no MCP/dispatcher seam) so an operator/Cowork walk has a
// stable CLI to point at a live page. Three modes are declared so the
// full exerciser surface is documented up front:
//
//   * `tab-walk`     — IMPLEMENTED here. Drives
//                      `BrowserPaneRunner.tabWalkFocusOrder(targetURL:steps:)`
//                      and prints the focus-order id sequence as JSON.
//   * `deadlock`     — DEFERRED. The watchdog-subprocess deadlock demo
//                      needs a live WKWebView + the exerciser's own e2e
//                      behavior; it stays with the parent's Cowork walk
//                      (process-gap-browserpane-direct-api-exerciser).
//   * `window-count` — DEFERRED. The NSWindow leak probe is a GUI-runtime
//                      behavior validated by the parent's Cowork walk.
//
// The two deferred modes print a structured `deferred-to-cowork-walk`
// sentinel and exit 0 so this child stays headless-testable: it never
// spawns a WKWebView or NSWindow from its own test corpus. The parent's
// Cowork walk fleshes the deferred modes out against a real WKWebView.
//
// Scope fence (Carmack): this CLI is the library-boundary + scaffold
// deliverable. `tab-walk` against a live page is an operator-driven run
// (it does allocate a WKWebView via BrowserPaneRunner), NOT part of this
// child's automated test envelope — the structural tests assert the
// mode dispatches to the public API without a live run.

struct BrowserPaneExerciser: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browserpane-exerciser",
        abstract: "Drive BrowserPaneRunner's public API directly for operator/Cowork validation walks."
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case tabWalk = "tab-walk"
        case deadlock
        case windowCount = "window-count"
    }

    @Option(name: .long, help: "Exerciser mode: tab-walk (implemented) | deadlock | window-count (deferred to the parent's Cowork walk).")
    var mode: Mode

    @Option(name: .long, help: "Target URL to drive (required for tab-walk).")
    var targetUrl: String?

    @Option(name: .long, help: "Tab-walk step count (default 10).")
    var steps: Int = 10

    @Option(name: .long, help: "Per-axis / page-load wall-clock timeout in seconds (default \(Int(BrowserPaneRunner.defaultAxisTimeout))).")
    var timeout: Double = BrowserPaneRunner.defaultAxisTimeout

    func run() throws {
        switch mode {
        case .tabWalk:
            try runTabWalk()
        case .deadlock, .windowCount:
            // Scope fence: the GUI-runtime modes stay with the parent's
            // Cowork walk. Emit the structured sentinel + exit 0.
            emitDeferredSentinel(mode: mode.rawValue)
        }
    }

    // MARK: - tab-walk

    private func runTabWalk() throws {
        guard let url = targetUrl, !url.isEmpty else {
            throw ValidationError("--mode tab-walk requires --target-url")
        }
        // Dispatch to the public BrowserPane API. The runner allocates an
        // off-screen WKWebView; `tabWalkFocusOrder` MUST run off the main
        // thread (WebKit IPC also runs on main — a main-thread call
        // deadlocks). The CLI's top-level is not the main run loop here,
        // but we run on a background queue + block to honor that contract.
        let runner = BrowserPaneRunner(axisTimeout: timeout)
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                box.ids = try runner.tabWalkFocusOrder(targetURL: url, steps: steps)
            } catch {
                box.error = error
            }
            sem.signal()
        }
        sem.wait()
        if let error = box.error {
            throw error
        }
        emitTabWalk(targetURL: url, ids: box.ids)
    }

    private func emitTabWalk(targetURL: String, ids: [String]) {
        let idsJSON = "[" + ids.map { "\"" + jsonEscape($0) + "\"" }.joined(separator: ",") + "]"
        let line = "{\"mode\":\"tab-walk\",\"target_url\":\"\(jsonEscape(targetURL))\",\"ids\":\(idsJSON)}"
        print(line)
    }

    private func emitDeferredSentinel(mode: String) {
        print("{\"mode\":\"\(jsonEscape(mode))\",\"status\":\"deferred-to-cowork-walk\"}")
    }

    private func jsonEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}

/// Box for transferring the tab-walk result/error out of the background
/// queue. Mutation is guarded by happens-before on the
/// `DispatchSemaphore.signal()`; `@unchecked Sendable` is the
/// hand-vouched contract (same idiom as BrowserPaneRunner's ErrorBox).
private final class ResultBox: @unchecked Sendable {
    var ids: [String] = []
    var error: Error?
}

BrowserPaneExerciser.main()
