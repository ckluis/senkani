import Foundation

/// V.13d — bridge OpenAI tool declarations onto senkani's EXISTING tool
/// surface. The acceptance contract is "no parallel tool registry": an
/// incoming OpenAI `tools: [{ function: { name, … } }]` is translated into
/// `MCPToolConfig` values (the process-wide `MCPToolCatalog` row type),
/// NOT a new bespoke registry. A function tool executes caller-supplied
/// behavior, so it bridges to the `.exec` tag — the same classification
/// `MCPToolCatalog.defaults` gives `senkani_exec` and `Bash` — and is
/// therefore confirmation-worthy by default.
public enum OpenAIToolBridge {

    /// Translate one OpenAI tool declaration into an `MCPToolConfig`.
    /// Function tools execute behavior → `.exec`.
    public static func mcpToolConfig(for tool: ChatCompletionRequest.Tool) -> MCPToolConfig {
        MCPToolConfig(name: tool.function.name, tags: [.exec])
    }

    /// Bridge every declared tool into `MCPToolConfig` values, deduping by
    /// name (last declaration wins) and preserving first-seen order. The
    /// return type is the existing catalog row type — proof that no
    /// parallel registry is introduced.
    public static func bridge(_ tools: [ChatCompletionRequest.Tool]) -> [MCPToolConfig] {
        var seen: Set<String> = []
        var order: [String] = []
        var byName: [String: MCPToolConfig] = [:]
        for tool in tools {
            let cfg = mcpToolConfig(for: tool)
            if seen.insert(cfg.name).inserted { order.append(cfg.name) }
            byName[cfg.name] = cfg   // last wins
        }
        return order.compactMap { byName[$0] }
    }

    /// The set of declared tool names, after bridging — used to confirm an
    /// emitted `tool_calls[].function.name` references a declared tool.
    public static func declaredNames(_ tools: [ChatCompletionRequest.Tool]) -> Set<String> {
        Set(tools.map(\.function.name))
    }
}
