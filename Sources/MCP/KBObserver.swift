import Foundation
import Core

/// Public bridge for entity mention observation from outside the MCPServer module.
/// SenkaniApp wires `HookRouter.entityObserver` to this so PostToolUse events
/// from native Claude Code tools flow into the default session's EntityTracker.
public enum KBObserver {

    /// Record entity mentions from a hook event's tool input.
    /// Extracts all string-valued fields and feeds them to the default session's
    /// EntityTracker.
    ///
    /// Fire-and-forget by design: hook callbacks must not block, so the
    /// registry lookup runs inside a detached Task. The actor cascade (Phase
    /// B-iii) enforces the contract — no synchronous read of the registry's
    /// session from outside the actor's executor.
    public static func observeHookEvent(toolName: String, toolInput: [String: Any]) {
        let texts = toolInput.values.compactMap { $0 as? String }.joined(separator: " ")
        guard !texts.isEmpty else { return }
        Task.detached(priority: .utility) {
            let tracker = await KBReader.tracker
            tracker.observe(text: texts, source: "hook:\(toolName)")
        }
    }
}
