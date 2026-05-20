import Foundation

/// V.10b — parses the four-slot rule set authored under
/// `spec/design_system_patterns.md` into a structured
/// `DesignSystemRuleSet` consumed by `DesignSystemStylesheet`.
///
/// Rule line format (under a canonical `## <slot>` heading):
///
///     - <token-name>: <value>
///
/// Lines outside the four canonical headings are ignored. All four
/// headings are required; the parser fails closed on any missing.
public enum DesignSystemPatternParser {

    public static func parse(_ markdown: String) throws -> DesignSystemRuleSet {
        var slots: [DesignSystemSlot: [DesignSystemRule]] = [:]
        var currentSlot: DesignSystemSlot?

        let lines = markdown.components(separatedBy: "\n")
        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("## ") {
                let headingText = String(line.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                currentSlot = DesignSystemSlot.from(heading: headingText)
                continue
            }

            guard line.hasPrefix("- "), let slot = currentSlot else { continue }

            let body = String(line.dropFirst(2))
            guard let colon = body.firstIndex(of: ":") else {
                throw DesignSystemPatternParseError.malformedLine(
                    lineNumber: idx + 1,
                    text: rawLine,
                    reason: "missing ':' separator between token and value"
                )
            }

            let token = String(body[..<colon])
                .trimmingCharacters(in: .whitespaces)
            let value = String(body[body.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if token.isEmpty {
                throw DesignSystemPatternParseError.malformedLine(
                    lineNumber: idx + 1,
                    text: rawLine,
                    reason: "empty token name"
                )
            }
            if value.isEmpty {
                throw DesignSystemPatternParseError.malformedLine(
                    lineNumber: idx + 1,
                    text: rawLine,
                    reason: "empty value"
                )
            }

            slots[slot, default: []].append(
                DesignSystemRule(token: token, value: value)
            )
        }

        for slot in DesignSystemSlot.allCases {
            if (slots[slot]?.isEmpty ?? true) {
                throw DesignSystemPatternParseError.missingSection(slot)
            }
        }

        return DesignSystemRuleSet(slots: slots)
    }
}

public struct DesignSystemRule: Equatable, Sendable {
    public let token: String
    public let value: String
    public init(token: String, value: String) {
        self.token = token
        self.value = value
    }
}

public struct DesignSystemRuleSet: Equatable, Sendable {
    public let slots: [DesignSystemSlot: [DesignSystemRule]]
    public init(slots: [DesignSystemSlot: [DesignSystemRule]]) {
        self.slots = slots
    }
    public var totalRuleCount: Int {
        slots.values.reduce(0) { $0 + $1.count }
    }
    public func rules(for slot: DesignSystemSlot) -> [DesignSystemRule] {
        slots[slot] ?? []
    }
}

public enum DesignSystemSlot: String, CaseIterable, Sendable {
    case spacing
    case contrast
    case hierarchy
    case typeScale

    public var heading: String {
        switch self {
        case .spacing:   return "Spacing"
        case .contrast:  return "Contrast"
        case .hierarchy: return "Hierarchy"
        case .typeScale: return "Type scale"
        }
    }

    static func from(heading: String) -> DesignSystemSlot? {
        let normalized = heading.lowercased()
        for slot in DesignSystemSlot.allCases {
            if slot.heading.lowercased() == normalized { return slot }
        }
        return nil
    }
}

public enum DesignSystemPatternParseError: Error, Equatable, Sendable {
    case missingSection(DesignSystemSlot)
    case malformedLine(lineNumber: Int, text: String, reason: String)
}
