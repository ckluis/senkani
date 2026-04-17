import Foundation
import MCP
import Core

enum SessionTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        let action = arguments?["action"]?.stringValue ?? "stats"

        switch action {
        case "stats":
            // Base stats + observability counters (ships with Observability
            // wave). Counters are per-project where the site knows it
            // (SSRF blocks, command redactions), process-global otherwise
            // (socket handshake rejections, schema migrations).
            var body = session.statsString()
            let securitySection = formatSecurityEvents(projectRoot: session.projectRoot)
            if !securitySection.isEmpty {
                body += "\n\n" + securitySection
            }
            return .init(content: [.text(text: body, annotations: nil, _meta: nil)])

        case "reset":
            session.readCache.clear()
            session.entityTracker.flush()
            session.entityTracker.resetSession()
            session.knowledgeStore.resetSessionMentions()
            return .init(content: [.text(text: "Session reset. Cache cleared, KB session state reset.", annotations: nil, _meta: nil)])

        case "config":
            if let features = arguments?["features"] {
                if case .object(let dict) = features {
                    let filter  = dict["filter"]?.boolValue
                    let secrets = dict["secrets"]?.boolValue
                    let indexer = dict["indexer"]?.boolValue
                    let cache   = dict["cache"]?.boolValue
                    let terse   = dict["terse"]?.boolValue
                    let autoPin = dict["auto_pin"]?.boolValue
                    let budgetCents = dict["budget_session_cents"]?.intValue

                    if let all = dict["all"]?.boolValue {
                        session.updateConfig(filter: all, secrets: all, indexer: all, cache: all, terse: all)
                    } else {
                        session.updateConfig(filter: filter, secrets: secrets, indexer: indexer,
                                             cache: cache, terse: terse, autoPin: autoPin,
                                             budgetSessionCents: budgetCents)
                    }
                }
            }
            return .init(content: [.text(text: "Config updated: \(session.configString())", annotations: nil, _meta: nil)])

        case "validators":
            // List all validators and their status
            var output = session.validatorRegistry.summaryString()

            // Handle enable/disable if specified
            if let name = arguments?["name"]?.stringValue,
               let enabled = arguments?["enabled"]?.boolValue {
                session.validatorRegistry.setEnabled(name: name, enabled: enabled)
                try? session.validatorRegistry.save(projectRoot: session.projectRoot)
                output = "Validator '\(name)' \(enabled ? "enabled" : "disabled").\n\n" + session.validatorRegistry.summaryString()
            }

            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])

        case "result":
            guard let resultId = arguments?["result_id"]?.stringValue else {
                return .init(content: [.text(text: "Error: 'result_id' is required for action 'result'.", annotations: nil, _meta: nil)], isError: true)
            }
            guard let result = SessionDatabase.shared.retrieveSandboxedResult(resultId: resultId) else {
                return .init(content: [.text(text: "Error: result '\(resultId)' not found (may have expired after 24h).", annotations: nil, _meta: nil)], isError: true)
            }
            var output = "// sandboxed result: \(resultId)\n"
            output += "// command: \(result.command)\n"
            output += "// \(result.lineCount) lines, \(result.byteCount) bytes\n"
            output += result.output
            return .init(content: [.text(text: output, annotations: nil, _meta: nil)])

        case "pin":
            guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
                return .init(content: [.text(text: "Error: 'name' is required for action 'pin'.", annotations: nil, _meta: nil)], isError: true)
            }
            let ttl = arguments?["ttl"]?.intValue ?? PinnedContextStore.defaultTTL
            let msg = session.pinContext(name: name, ttl: ttl)
            return .init(content: [.text(text: msg, annotations: nil, _meta: nil)])

        case "unpin":
            guard let name = arguments?["name"]?.stringValue, !name.isEmpty else {
                return .init(content: [.text(text: "Error: 'name' is required for action 'unpin'.", annotations: nil, _meta: nil)], isError: true)
            }
            session.pinnedContextStore.unpin(name: name)
            return .init(content: [.text(text: "Unpinned: \(name)", annotations: nil, _meta: nil)])

        case "pins":
            let all = session.pinnedContextStore.all()
            if all.isEmpty {
                return .init(content: [.text(text: "No pinned context entries.", annotations: nil, _meta: nil)])
            }
            let lines = all.map { e in
                "  @\(e.name) — \(e.callsRemaining)/\(e.maxCalls) calls remaining"
            }
            return .init(content: [.text(text: "Pinned context (\(all.count)/\(PinnedContextStore.maxEntries)):\n" + lines.joined(separator: "\n"), annotations: nil, _meta: nil)])

        default:
            return .init(content: [.text(text: "Unknown action: \(action). Valid actions: 'stats', 'reset', 'config', 'validators', 'result', 'pin', 'unpin', 'pins'.", annotations: nil, _meta: nil)], isError: true)
        }
    }

    /// Observability dashboard fragment appended to `senkani_session stats`.
    /// Queries `event_counters` for both project-scoped and process-global
    /// rows so the operator sees the full security posture. Returns empty
    /// string when nothing has fired yet (avoid noisy dashboards on fresh
    /// installs).
    private static func formatSecurityEvents(projectRoot: String) -> String {
        let projectRows = SessionDatabase.shared.eventCounts(projectRoot: projectRoot)
        let globalRows = SessionDatabase.shared.eventCounts(projectRoot: "")
        // Merge: global rows supplement project rows. If both exist for the
        // same event type, show them distinctly.
        var lines: [String] = []
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        func emit(_ rows: [SessionDatabase.EventCountRow], scope: String) {
            for r in rows {
                lines.append("  \(r.eventType)  count=\(r.count)  last=\(df.string(from: r.lastSeenAt))  [\(scope)]")
            }
        }
        if !projectRows.isEmpty {
            lines.append("Security events (this project):")
            emit(projectRows, scope: "project")
        }
        if !globalRows.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("Security events (process-global):")
            emit(globalRows, scope: "global")
        }
        return lines.joined(separator: "\n")
    }
}
