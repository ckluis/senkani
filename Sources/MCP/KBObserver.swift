import Foundation
import Core

/// Public bridge for entity mention observation from outside the MCPServer module.
/// SenkaniApp wires `HookRouter.entityObserver` to this so PostToolUse events
/// from native Claude Code tools flow into MCPSession's EntityTracker.
public enum KBObserver {

    /// Record entity mentions from a hook event's tool input.
    /// Extracts all string-valued fields and feeds them to the shared session's EntityTracker.
    /// Safe to call from any thread (EntityTracker is NSLock-backed).
    public static func observeHookEvent(toolName: String, toolInput: [String: Any]) {
        let texts = toolInput.values.compactMap { $0 as? String }.joined(separator: " ")
        guard !texts.isEmpty else { return }
        MCPSession.shared.entityTracker.observe(text: texts, source: "hook:\(toolName)")
    }
}
