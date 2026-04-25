import Foundation
import Testing
@testable import Indexer

// MARK: - Per-Language Import Extraction

@Suite("DependencyGraph — Per-Language Import Extraction")
struct ImportExtractionTests {

    @Test("Swift imports")
    func extractsSwiftImports() {
        let source = """
        import Foundation
        import Core
        @testable import Filter
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "swift")
        #expect(imports.contains("Foundation"))
        #expect(imports.contains("Core"))
        #expect(imports.contains("Filter"))
    }

    @Test("Python imports")
    func extractsPythonImports() {
        let source = """
        import os
        from pathlib import Path
        import json
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "python")
        #expect(imports.contains("os"))
        #expect(imports.contains("pathlib"))
        #expect(imports.contains("json"))
    }

    @Test("TypeScript imports")
    func extractsTypeScriptImports() {
        let source = """
        import { foo } from './bar'
        import baz from 'lodash'
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "typescript")
        #expect(imports.contains("./bar"))
        #expect(imports.contains("lodash"))
    }

    @Test("Go imports")
    func extractsGoImports() {
        let source = """
        package main

        import "fmt"
        import (
          "os"
          "strings"
        )
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "go")
        #expect(imports.contains("fmt"))
        #expect(imports.contains("os"))
        #expect(imports.contains("strings"))
    }

    @Test("Rust imports")
    func extractsRustImports() {
        let source = """
        use std::io::Read;
        use foo::bar;
        extern crate baz;
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "rust")
        #expect(imports.contains("std"))
        #expect(imports.contains("foo"))
        #expect(imports.contains("baz"))
    }

    @Test("Java imports")
    func extractsJavaImports() {
        let source = """
        package com.example;

        import java.util.List;
        import java.util.Map;
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "java")
        #expect(imports.contains("java.util.List"))
        #expect(imports.contains("java.util.Map"))
    }

    @Test("C includes")
    func extractsCImports() {
        let source = """
        #include <stdio.h>
        #include "myheader.h"
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "c")
        #expect(imports.contains("stdio.h"))
        #expect(imports.contains("myheader.h"))
    }

    @Test("Ruby requires")
    func extractsRubyImports() {
        let source = """
        require 'json'
        require_relative '../helpers'
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "ruby")
        #expect(imports.contains("json"))
        #expect(imports.contains("../helpers"))
    }

    @Test("Elixir aliases")
    func extractsElixirAliases() {
        let source = """
        defmodule MyMod do
          alias MyApp.Web.Helper
          import Ecto.Query
          use GenServer
        end
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "elixir")
        #expect(imports.contains("MyApp.Web.Helper"))
        #expect(imports.contains("Ecto.Query"))
        #expect(imports.contains("GenServer"))
    }

    @Test("Zig @import")
    func extractsZigImports() {
        let source = """
        const std = @import("std");
        const builtin = @import("builtin");
        """
        let imports = DependencyExtractor.extractImports(source: source, language: "zig")
        #expect(imports.contains("std"))
        #expect(imports.contains("builtin"))
    }
}

// MARK: - Graph Construction

@Suite("DependencyGraph — Graph Construction")
struct GraphConstructionTests {

    @Test("Builds forward and reverse graph")
    func buildsForwardAndReverseGraph() {
        // Build the graph from known import data — tests the DependencyGraph model
        // and DependencyExtractor without depending on FileWalker path resolution.
        let sourceA = "import Foundation\nimport Core\n"
        let sourceB = "import Foundation\n"

        let importsA = DependencyExtractor.extractImports(source: sourceA, language: "swift")
        let importsB = DependencyExtractor.extractImports(source: sourceB, language: "swift")

        var imports: [String: [String]] = [:]
        var importedBy: [String: [String]] = [:]
        imports["fileA.swift"] = importsA
        imports["fileB.swift"] = importsB
        for (file, modules) in imports {
            for module in modules {
                importedBy[module, default: []].append(file)
            }
        }

        let graph = DependencyGraph(
            imports: imports,
            importedBy: importedBy,
            projectRoot: "/tmp/test"
        )

        // Forward: what does each file import?
        let depsA = graph.dependencies(of: "fileA.swift")
        #expect(depsA.contains("Foundation"))
        #expect(depsA.contains("Core"))

        let depsB = graph.dependencies(of: "fileB.swift")
        #expect(depsB.contains("Foundation"))
        #expect(!depsB.contains("Core"))

        // Reverse: what files import Foundation?
        let foundationDependents = graph.dependents(of: "Foundation")
        #expect(foundationDependents.contains("fileA.swift"))
        #expect(foundationDependents.contains("fileB.swift"))

        // Reverse: what files import Core?
        let coreDependents = graph.dependents(of: "Core")
        #expect(coreDependents.contains("fileA.swift"))
        #expect(!coreDependents.contains("fileB.swift"))
    }

    @Test("Real project graph builds fast")
    func buildGraphFromRealProject() {
        // Build dep graph from senkani's own source tree
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SenkaniTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // senkani/
            .resolvingSymlinksInPath()
            .path

        let clock = ContinuousClock()
        var graph: DependencyGraph?
        let elapsed = clock.measure {
            graph = IndexEngine.buildDependencyGraph(projectRoot: projectRoot)
        }

        // Machine-load-dependent timing guard. The regression this rules out
        // (accidentally O(N²) re-parse) costs minutes, not seconds — widen
        // to 5s for parallel-test-run headroom without losing signal.
        #expect(elapsed < .seconds(5))

        // Sanity: Core should be imported by multiple files
        let coreDependents = graph!.dependents(of: "Core")
        #expect(coreDependents.count > 1)

        // MCPSession.swift should import something
        let mcpDeps = graph!.dependencies(of: "Sources/MCP/Session/MCPSession.swift")
        #expect(!mcpDeps.isEmpty)
    }
}

// MARK: - Tool Output

@Suite("DependencyGraph — Tool Output")
struct ToolOutputTests {

    @Test("Both directions output format")
    func depsToolOutputFormatBoth() {
        let graph = DependencyGraph(
            imports: ["src/app.swift": ["Foundation", "Core"]],
            importedBy: ["Foundation": ["src/app.swift", "src/lib.swift"], "Core": ["src/app.swift"]],
            projectRoot: "/tmp/test"
        )

        // Simulate DepsTool's output logic for "both" direction
        let target = "src/app.swift"
        var lines: [String] = []
        let deps = graph.dependencies(of: target)
        lines.append("\(target) imports (\(deps.count)):")
        for dep in deps { lines.append("  → \(dep)") }
        lines.append("")
        let dependents = graph.dependents(of: target)
        if !dependents.isEmpty {
            lines.append("Imported by (\(dependents.count) files):")
        } else {
            lines.append("Imported by: (none found)")
        }

        let output = lines.joined(separator: "\n")
        #expect(output.contains("imports (2)"))
        #expect(output.contains("→ Foundation"))
        #expect(output.contains("→ Core"))
        #expect(output.contains("Imported by:"))
    }

    @Test("Circular imports build correctly — no crash, no duplicate edges")
    func circularImportGraph() {
        // A.swift imports B.swift, B.swift imports A.swift — a simple cycle.
        // DependencyGraph stores edges as provided; this verifies no crash or
        // data corruption when circular references are present in the import map.
        let graph = DependencyGraph(
            imports: ["A.swift": ["B.swift"], "B.swift": ["A.swift"]],
            importedBy: ["A.swift": ["B.swift"], "B.swift": ["A.swift"]],
            projectRoot: "/tmp/test"
        )

        let depsOfA = graph.dependencies(of: "A.swift")
        let depsOfB = graph.dependencies(of: "B.swift")

        #expect(depsOfA.contains("B.swift"), "A should depend on B")
        #expect(depsOfB.contains("A.swift"), "B should depend on A")

        // No duplicate edges (the graph must not double-insert)
        #expect(Set(depsOfA).count == depsOfA.count, "No duplicate edges for A")
        #expect(Set(depsOfB).count == depsOfB.count, "No duplicate edges for B")

        // Reverse graph is also correct
        let dependentsOfA = graph.dependents(of: "A.swift")
        let dependentsOfB = graph.dependents(of: "B.swift")
        #expect(dependentsOfB.contains("A.swift"), "A imports B → B is depended on by A")
        #expect(dependentsOfA.contains("B.swift"), "B imports A → A is depended on by B")
    }

    @Test("Single direction output format")
    func depsToolOutputFormatSingle() {
        let graph = DependencyGraph(
            imports: ["src/app.swift": ["Foundation", "Core"]],
            importedBy: ["Foundation": ["src/app.swift", "src/lib.swift"]],
            projectRoot: "/tmp/test"
        )

        // Simulate DepsTool's output for "imports" only
        let target = "src/app.swift"
        let direction = "imports"
        var lines: [String] = []
        if direction == "both" || direction == "imports" {
            let deps = graph.dependencies(of: target)
            lines.append("\(target) imports (\(deps.count)):")
            for dep in deps { lines.append("  → \(dep)") }
        }

        let output = lines.joined(separator: "\n")
        #expect(output.contains("imports (2)"))
        #expect(output.contains("→ Foundation"))
        #expect(!output.contains("Imported by"))
    }
}
