import Foundation

/// V.10b — turns a parsed `DesignSystemRuleSet` into a single
/// deterministic CSS string. Same input twice yields byte-identical
/// output. No clock, no random, no file I/O.
///
/// Layout:
///   `:root { --<slot>-<token>: <value>; ... }` — every token a CSS
///   custom property under `:root`, lexically sorted within slot.
///   `body { font-family: ...; line-height: ...; color: ...; background: ...; }`
///   `h1 { font-size: ...; font-weight: ...; }`
///   `h2 { font-size: ...; }`
///   `h3 { font-size: ...; }`
///
/// Three minimum surfaces (`:root`, `body`, `h1`) are guaranteed so
/// the toggle feels visibly different to the operator.
public enum DesignSystemStylesheet {

    public static func css(from ruleSet: DesignSystemRuleSet) -> String {
        var out = ""

        // :root — custom properties for every token, deterministic order.
        out += ":root {\n"
        for slot in DesignSystemSlot.allCases {
            let rules = ruleSet.rules(for: slot).sorted { $0.token < $1.token }
            for rule in rules {
                let cssName = cssVariableName(slot: slot, token: rule.token)
                out += "  \(cssName): \(escapeValue(rule.value));\n"
            }
        }
        out += "}\n"

        // body — type scale base, body family, body fg/bg, line-height.
        let typeFamily = lookup(ruleSet, slot: .typeScale, token: "typeScale.body-family") ?? "system-ui, sans-serif"
        let lineHeight = lookup(ruleSet, slot: .typeScale, token: "typeScale.line-height") ?? "1.5"
        let bodyFg     = lookup(ruleSet, slot: .contrast,  token: "contrast.body-fg") ?? "#1a1a1a"
        let bodyBg     = lookup(ruleSet, slot: .contrast,  token: "contrast.body-bg") ?? "#ffffff"
        let typeBase   = lookup(ruleSet, slot: .typeScale, token: "typeScale.base") ?? "1rem"
        let padInline  = lookup(ruleSet, slot: .spacing,   token: "spacing.pad-inline") ?? "16px"
        let padBlock   = lookup(ruleSet, slot: .spacing,   token: "spacing.pad-block") ?? "16px"

        out += "body {\n"
        out += "  font-family: \(escapeValue(typeFamily));\n"
        out += "  font-size: \(escapeValue(typeBase));\n"
        out += "  line-height: \(escapeValue(lineHeight));\n"
        out += "  color: \(escapeValue(bodyFg));\n"
        out += "  background: \(escapeValue(bodyBg));\n"
        out += "  padding: \(escapeValue(padBlock)) \(escapeValue(padInline));\n"
        out += "}\n"

        // h1/h2/h3 — hierarchy scale.
        let h1Scale = lookup(ruleSet, slot: .hierarchy, token: "hierarchy.h1-scale") ?? "2.4"
        let h2Scale = lookup(ruleSet, slot: .hierarchy, token: "hierarchy.h2-scale") ?? "1.8"
        let h3Scale = lookup(ruleSet, slot: .hierarchy, token: "hierarchy.h3-scale") ?? "1.4"
        let sectionWeight = lookup(ruleSet, slot: .hierarchy, token: "hierarchy.section-mark-weight") ?? "600"

        out += "h1 {\n"
        out += "  font-size: calc(\(escapeValue(typeBase)) * \(escapeValue(h1Scale)));\n"
        out += "  font-weight: \(escapeValue(sectionWeight));\n"
        out += "}\n"
        out += "h2 {\n"
        out += "  font-size: calc(\(escapeValue(typeBase)) * \(escapeValue(h2Scale)));\n"
        out += "  font-weight: \(escapeValue(sectionWeight));\n"
        out += "}\n"
        out += "h3 {\n"
        out += "  font-size: calc(\(escapeValue(typeBase)) * \(escapeValue(h3Scale)));\n"
        out += "}\n"

        return out
    }

    private static func cssVariableName(slot: DesignSystemSlot, token: String) -> String {
        // token may include the slot prefix (e.g. "spacing.unit"); drop the prefix
        // to keep names like `--spacing-unit` rather than `--spacing-spacing-unit`.
        let trimmed: String
        let slotPrefix = slot.rawValue + "."
        if token.hasPrefix(slotPrefix) {
            trimmed = String(token.dropFirst(slotPrefix.count))
        } else {
            trimmed = token
        }
        let dashed = trimmed.replacingOccurrences(of: ".", with: "-")
        return "--\(slot.rawValue.lowercased())-\(dashed)"
    }

    private static func lookup(_ ruleSet: DesignSystemRuleSet,
                               slot: DesignSystemSlot,
                               token: String) -> String? {
        ruleSet.rules(for: slot).first(where: { $0.token == token })?.value
    }

    private static func escapeValue(_ value: String) -> String {
        // CSS values: trim surrounding whitespace and neutralize any `}` that
        // would end the rule prematurely. The parser already rejects empty
        // values; here we only defend against accidental rule-termination.
        return value.replacingOccurrences(of: "}", with: "")
    }
}
