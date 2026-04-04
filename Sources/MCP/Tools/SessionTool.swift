import Foundation
import MCP
import Core

enum SessionTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        let action = arguments?["action"]?.stringValue ?? "stats"

        switch action {
        case "stats":
            return .init(content: [.text(text: session.statsString(), annotations: nil, _meta: nil)])

        case "reset":
            session.readCache.clear()
            return .init(content: [.text(text: "Session reset. Cache cleared, metrics zeroed.", annotations: nil, _meta: nil)])

        case "config":
            if let features = arguments?["features"] {
                if case .object(let dict) = features {
                    let filter = dict["filter"]?.boolValue
                    let secrets = dict["secrets"]?.boolValue
                    let indexer = dict["indexer"]?.boolValue
                    let cache = dict["cache"]?.boolValue

                    if let all = dict["all"]?.boolValue {
                        session.updateConfig(filter: all, secrets: all, indexer: all, cache: all)
                    } else {
                        session.updateConfig(filter: filter, secrets: secrets, indexer: indexer, cache: cache)
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

        default:
            return .init(content: [.text(text: "Unknown action: \(action). Use 'stats', 'reset', 'config', or 'validators'.", annotations: nil, _meta: nil)], isError: true)
        }
    }
}
