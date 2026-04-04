import Foundation
import MCP

/// Extracts structured results from build/test/lint output at $0.
/// Agent sees "1 failed: testFoo at line 42" instead of 500 lines of raw output.
enum ParseTool {
    static func handle(arguments: [String: Value]?, session: MCPSession) -> CallTool.Result {
        guard let output = arguments?["output"]?.stringValue else {
            return .init(content: [.text(text: "Error: 'output' is required", annotations: nil, _meta: nil)], isError: true)
        }

        let typeHint = arguments?["type"]?.stringValue?.lowercased()
        let rawBytes = output.utf8.count

        // Auto-detect type if not specified
        let detectedType = typeHint ?? detectType(output)
        let parsed: String

        switch detectedType {
        case "test":
            parsed = parseTestOutput(output)
        case "build":
            parsed = parseBuildOutput(output)
        case "lint":
            parsed = parseLintOutput(output)
        case "error":
            parsed = parseErrorOutput(output)
        default:
            // Generic: strip noise, keep important lines
            parsed = parseGeneric(output)
        }

        let parsedBytes = parsed.utf8.count
        let savedPct = rawBytes > 0 ? Int(Double(rawBytes - parsedBytes) / Double(rawBytes) * 100) : 0

        session.recordMetrics(rawBytes: rawBytes, compressedBytes: parsedBytes, feature: "parse",
                              command: "parse", outputPreview: String(parsed.prefix(200)))

        let header = "// senkani_parse (\(detectedType)): \(rawBytes) → \(parsedBytes) bytes (\(savedPct)% saved)\n"
        return .init(content: [.text(text: header + parsed, annotations: nil, _meta: nil)])
    }

    // MARK: - Type detection

    private static func detectType(_ output: String) -> String {
        let lower = output.lowercased()
        if lower.contains("test run") || lower.contains("tests passed") || lower.contains("tests failed")
            || lower.contains("✔ test") || lower.contains("✘ test") || lower.contains("pass")
            && lower.contains("fail") {
            return "test"
        }
        if lower.contains("error:") && (lower.contains("compiling") || lower.contains("build")) {
            return "build"
        }
        if lower.contains("warning:") && lower.contains("violation") || lower.contains("lint") {
            return "lint"
        }
        if lower.contains("traceback") || lower.contains("stack trace") || lower.contains("fatal error")
            || lower.contains("panic:") || lower.contains("exception") {
            return "error"
        }
        return "generic"
    }

    // MARK: - Test output parser

    private static func parseTestOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var passed = 0
        var failed = 0
        var failures: [String] = []
        var duration: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Swift Testing format: ✔ Test name() passed / ✘ Test name() failed
            if trimmed.contains("✔") && trimmed.lowercased().contains("passed") {
                passed += 1
            } else if trimmed.contains("✘") && trimmed.lowercased().contains("failed") {
                failed += 1
                failures.append(trimmed)
            }
            // Swift Testing summary: Test run with N tests passed/failed
            else if trimmed.contains("Test run with") {
                duration = trimmed
            }
            // XCTest format
            else if trimmed.hasPrefix("Test Case") && trimmed.contains("passed") {
                passed += 1
            } else if trimmed.hasPrefix("Test Case") && trimmed.contains("failed") {
                failed += 1
                failures.append(trimmed)
            }
            // Jest/pytest format
            else if trimmed.contains("PASS ") || trimmed.contains(" passed") {
                if let n = extractNumber(from: trimmed, before: "passed") { passed += n }
            } else if trimmed.contains("FAIL ") || trimmed.contains(" failed") {
                if let n = extractNumber(from: trimmed, before: "failed") { failed += n }
            }
            // Capture assertion failures and expectation details
            else if trimmed.contains("Expectation failed") || trimmed.contains("XCTAssert")
                || trimmed.contains("AssertionError") || trimmed.contains("expect(") {
                failures.append(trimmed)
            }
        }

        var result = "Tests: \(passed) passed, \(failed) failed"
        if let dur = duration { result += " (\(dur))" }
        result += "\n"

        if !failures.isEmpty {
            result += "\nFailures:\n"
            for f in failures.prefix(10) {
                result += "  \(f)\n"
            }
            if failures.count > 10 {
                result += "  ... and \(failures.count - 10) more\n"
            }
        }

        return result
    }

    // MARK: - Build output parser

    private static func parseBuildOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var errors: [String] = []
        var warnings: [String] = []
        var buildResult: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("error:") && !trimmed.hasPrefix("//") {
                errors.append(trimmed)
            } else if trimmed.contains("warning:") && !trimmed.hasPrefix("//") {
                warnings.append(trimmed)
            } else if trimmed.contains("Build complete") || trimmed.contains("BUILD SUCCESSFUL")
                || trimmed.contains("Build failed") || trimmed.contains("BUILD FAILED") {
                buildResult = trimmed
            }
        }

        var result = ""
        if let br = buildResult { result += "\(br)\n" }
        result += "\(errors.count) error(s), \(warnings.count) warning(s)\n"

        if !errors.isEmpty {
            result += "\nErrors:\n"
            for e in errors.prefix(20) {
                result += "  \(e)\n"
            }
        }

        if !warnings.isEmpty {
            result += "\nWarnings:\n"
            for w in warnings.prefix(10) {
                result += "  \(w)\n"
            }
            if warnings.count > 10 {
                result += "  ... and \(warnings.count - 10) more\n"
            }
        }

        return result
    }

    // MARK: - Lint output parser

    private static func parseLintOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var violations: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Common lint patterns: file:line:col: severity: message
            if trimmed.contains(":") && (trimmed.contains("error") || trimmed.contains("warning")
                || trimmed.contains("violation")) {
                violations.append(trimmed)
            }
        }

        if violations.isEmpty { return "No lint violations found.\n" }

        var result = "\(violations.count) violation(s):\n"
        for v in violations.prefix(20) {
            result += "  \(v)\n"
        }
        if violations.count > 20 {
            result += "  ... and \(violations.count - 20) more\n"
        }
        return result
    }

    // MARK: - Error/stack trace parser

    private static func parseErrorOutput(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var category = "Unknown error"
        var keyLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Categorize error
            if trimmed.contains("ModuleNotFoundError") || trimmed.contains("No such module") {
                category = "Missing dependency"
            } else if trimmed.contains("SyntaxError") || trimmed.contains("syntax error") {
                category = "Syntax error"
            } else if trimmed.contains("TypeError") || trimmed.contains("type mismatch") {
                category = "Type error"
            } else if trimmed.contains("Permission denied") || trimmed.contains("EACCES") {
                category = "Permission error"
            } else if trimmed.contains("ENOENT") || trimmed.contains("No such file") {
                category = "File not found"
            } else if trimmed.contains("Connection refused") || trimmed.contains("ECONNREFUSED") {
                category = "Connection error"
            } else if trimmed.contains("OutOfMemory") || trimmed.contains("MemoryError") {
                category = "Memory error"
            }

            // Keep error lines and the most relevant context
            if trimmed.contains("Error") || trimmed.contains("error:") || trimmed.contains("panic:")
                || trimmed.contains("fatal") || trimmed.contains("Traceback")
                || trimmed.hasPrefix("at ") || trimmed.hasPrefix("File \"") {
                keyLines.append(trimmed)
            }
        }

        var result = "Category: \(category)\n\n"
        for line in keyLines.prefix(15) {
            result += "  \(line)\n"
        }
        if keyLines.count > 15 {
            result += "  ... (\(keyLines.count - 15) more lines)\n"
        }
        return result
    }

    // MARK: - Generic parser (fallback)

    private static func parseGeneric(_ output: String) -> String {
        let lines = output.components(separatedBy: "\n")
        var important: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // Keep lines that contain actionable info
            if trimmed.contains("error") || trimmed.contains("Error")
                || trimmed.contains("warning") || trimmed.contains("Warning")
                || trimmed.contains("failed") || trimmed.contains("FAIL")
                || trimmed.contains("passed") || trimmed.contains("PASS")
                || trimmed.contains("✔") || trimmed.contains("✘")
                || trimmed.contains("✓") || trimmed.contains("✗")
                || trimmed.hasPrefix("fatal") || trimmed.hasPrefix("panic") {
                important.append(trimmed)
            }
        }

        if important.isEmpty {
            // Nothing actionable found, return truncated original
            if lines.count > 20 {
                return lines.prefix(10).joined(separator: "\n") + "\n... (\(lines.count - 20) lines)\n" + lines.suffix(10).joined(separator: "\n")
            }
            return output
        }

        var result = "\(important.count) notable line(s) from \(lines.count) total:\n"
        for line in important.prefix(30) {
            result += "  \(line)\n"
        }
        return result
    }

    // MARK: - Helpers

    private static func extractNumber(from text: String, before keyword: String) -> Int? {
        let pattern = "(\\d+)\\s+\(keyword)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}
