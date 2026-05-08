import Testing
import Foundation
import MCP
@testable import MCPServer

/// Verifies the `ToolRegistry` is the single source of truth for the MCP tool
/// surface — i.e. the dispatch table and the `allTools()` schema list cannot
/// drift apart. With the typed registry there is one `ToolDefinition` per
/// tool, so closure of the two surfaces is structural rather than incidental.
@Suite("ToolRouterRegistry")
struct ToolRouterRegistryTests {

    @Test func dispatchAndCatalogShareTheSameNameSet() {
        let catalogNames = Set(ToolRouter.allTools().map(\.name))
        let dispatchableNames = Set(ToolRegistry.byName.keys)
        #expect(catalogNames == dispatchableNames,
                "every tool advertised in allTools() must be dispatchable, and vice versa")
    }

    @Test func toolNamesAreUnique() {
        let names = ToolRegistry.definitions.map(\.name)
        #expect(Set(names).count == names.count, "tool names must be unique")
    }

    @Test func byNameLookupAgreesWithDefinitions() {
        for def in ToolRegistry.definitions {
            #expect(ToolRegistry.byName[def.name]?.name == def.name,
                    "byName lookup must resolve every registered tool")
        }
        #expect(ToolRegistry.byName.count == ToolRegistry.definitions.count,
                "byName count must match definitions count (no name collisions)")
    }

    @Test func schemaNameMatchesDefinitionName() {
        for def in ToolRegistry.definitions {
            #expect(def.schema.name == def.name,
                    "ToolDefinition.name must match its schema.name (\(def.name) vs \(def.schema.name))")
        }
    }

    @Test func registryCoversAllPreviouslyDispatchedTools() {
        // Pin the historical tool set so an accidental deletion is caught
        // even if the registry-vs-catalog symmetry stays trivially true.
        let expected: Set<String> = [
            "read", "exec", "search", "fetch", "web", "search_web",
            "explore", "outline", "session", "validate", "parse",
            "embed", "vision", "deps", "pane", "watch", "version",
            "repo", "bundle", "knowledge",
        ]
        let actual = Set(ToolRegistry.byName.keys)
        #expect(actual == expected,
                "tool surface drift: missing=\(expected.subtracting(actual)) extra=\(actual.subtracting(expected))")
    }
}
