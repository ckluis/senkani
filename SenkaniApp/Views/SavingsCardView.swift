import SwiftUI

// MARK: - Feature Toggle (Compact)

/// Compact feature toggle letter. Tap to toggle on/off.
struct FeatureToggleCompact: View {
    let label: String
    @Binding var isOn: Bool
    let color: Color

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(isOn ? color : SenkaniTheme.textTertiary.opacity(0.5))
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isOn ? color.opacity(0.1) : Color.clear)
            )
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
    }
}

// MARK: - Feature Info Model

struct FeatureInfo {
    let name: String
    let icon: String
    let tagline: String
    let description: String
    let benefits: [String]
    let savingsRange: String

    static func lookup(_ key: String) -> FeatureInfo {
        switch key {
        case "filter": return FeatureInfo(
            name: "Filter",
            icon: "line.3.horizontal.decrease.circle",
            tagline: "Output Compression",
            description: "Strips ANSI escape codes, deduplicates repeated lines, and applies 24 command-specific compression rules for git, npm, cargo, docker, and more.",
            benefits: [
                "60-90% reduction on build/test output",
                "Removes terminal color noise from AI context",
                "Smart dedup for repeated warnings/errors"
            ],
            savingsRange: "60-90%"
        )
        case "cache": return FeatureInfo(
            name: "Cache",
            icon: "arrow.triangle.2.circlepath",
            tagline: "Session File Cache",
            description: "Tracks file checksums within a session. When an agent re-reads an unchanged file, returns instantly from cache instead of re-processing.",
            benefits: [
                "50-99% savings on repeated file reads",
                "Instant response for unchanged files",
                "Eliminates redundant disk I/O"
            ],
            savingsRange: "50-99%"
        )
        case "secrets": return FeatureInfo(
            name: "Secrets",
            icon: "lock.shield",
            tagline: "Secret Redaction",
            description: "Detects and redacts API keys, tokens, passwords, and credentials before they reach the AI model. Prevents accidental secret leakage in prompts.",
            benefits: [
                "Auto-detects 7 secret patterns",
                "Redacts before tokens leave your machine",
                "Protects API keys, JWTs, private keys"
            ],
            savingsRange: "security"
        )
        case "indexer": return FeatureInfo(
            name: "Indexer",
            icon: "list.bullet.indent",
            tagline: "Symbol Navigation",
            description: "Builds a lightweight symbol index of your codebase. Agents can find functions, classes, and types by name instead of grepping entire files.",
            benefits: [
                "~95% fewer tokens vs full file reads",
                "Instant symbol lookup by name or kind",
                "Auto-indexes on first call per session"
            ],
            savingsRange: "~95%"
        )
        case "terse": return FeatureInfo(
            name: "Terse",
            icon: "text.word.spacing",
            tagline: "Output Minimization",
            description: "Injects a system prompt that instructs the AI to minimize output tokens. No preamble, no narration, no summaries \u{2014} just results.",
            benefits: [
                "50-75% fewer output tokens",
                "Faster responses, lower cost",
                "Eliminates filler phrases and narration"
            ],
            savingsRange: "50-75%"
        )
        default: return FeatureInfo(
            name: key.capitalized, icon: "questionmark.circle",
            tagline: "", description: "", benefits: [], savingsRange: ""
        )
        }
    }
}

// MARK: - Feature Detail Drawer

/// Expandable detail panel for Phase 3.
/// Shows per-feature stats, top commands, and a "how it works" description.
struct FeatureDetailDrawer: View {
    let featureKey: String
    @Bindable var pane: PaneModel

    private var info: FeatureInfo { FeatureInfo.lookup(featureKey) }

    private var color: Color {
        switch featureKey {
        case "filter": return SenkaniTheme.toggleFilter
        case "cache": return SenkaniTheme.toggleCache
        case "secrets": return SenkaniTheme.toggleSecrets
        case "indexer": return SenkaniTheme.toggleIndexer
        case "terse": return SenkaniTheme.toggleTerse
        default: return SenkaniTheme.textSecondary
        }
    }

    private var isOn: Bool {
        switch featureKey {
        case "filter": return pane.features.filter
        case "cache": return pane.features.cache
        case "secrets": return pane.features.secrets
        case "indexer": return pane.features.indexer
        case "terse": return pane.features.terse
        default: return false
        }
    }

    private var featureSaved: Int {
        pane.metrics.perFeatureSaved[featureKey, default: 0]
    }

    private var featureCommandCount: Int {
        pane.metrics.perFeatureCommandCount[featureKey, default: 0]
    }

    private var featurePercent: String {
        guard pane.metrics.totalRawBytes > 0 else { return "0%" }
        let pct = Double(featureSaved) / Double(pane.metrics.totalRawBytes) * 100
        return String(format: "%.0f%%", pct)
    }

    private var topCommands: [(command: String, saved: Int)] {
        pane.metrics.topCommands(for: featureKey, limit: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: info.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .frame(width: 16)

                Text(info.name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)

                Text(info.tagline)
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textSecondary)

                Spacer()

                Text(isOn ? "ON" : "OFF")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(isOn ? color : SenkaniTheme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(isOn ? color.opacity(0.15) : SenkaniTheme.textTertiary.opacity(0.1))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            drawerDivider

            // Stats row
            if featureSaved > 0 || featureCommandCount > 0 {
                HStack(spacing: 4) {
                    if featureSaved > 0 {
                        Text(formatBytes(featureSaved))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                        Text("saved")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text("(\(featurePercent))")
                            .foregroundStyle(color)
                    }
                    if featureCommandCount > 0 {
                        Text("\u{00b7}")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text("\(featureCommandCount) cmd\(featureCommandCount == 1 ? "" : "s")")
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }
                    Spacer()
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            } else {
                HStack(spacing: 4) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Text(info.savingsRange == "security"
                        ? "Active protection \u{2014} stats appear when secrets are detected"
                        : "Expected savings: \(info.savingsRange) \u{2014} run some commands to see results")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            // Top commands
            if !topCommands.isEmpty {
                drawerDivider

                VStack(alignment: .leading, spacing: 2) {
                    Text("TOP COMMANDS")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .padding(.bottom, 1)

                    ForEach(Array(topCommands.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.command)
                                .foregroundStyle(SenkaniTheme.textPrimary)
                            Spacer()
                            Text(formatBytes(entry.saved))
                                .foregroundStyle(SenkaniTheme.savingsGreen)
                        }
                        .font(.system(size: 9, design: .monospaced))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            // Secret patterns (secrets feature only)
            if featureKey == "secrets" && !pane.metrics.secretPatterns.isEmpty {
                drawerDivider

                VStack(alignment: .leading, spacing: 2) {
                    Text("PATTERNS CAUGHT")
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .padding(.bottom, 1)

                    ForEach(
                        pane.metrics.secretPatterns.sorted(by: { $0.value > $1.value }),
                        id: \.key
                    ) { pattern, count in
                        HStack {
                            Text(pattern)
                                .foregroundStyle(SenkaniTheme.textPrimary)
                            Spacer()
                            Text("\u{00d7}\(count)")
                                .foregroundStyle(color)
                        }
                        .font(.system(size: 9, design: .monospaced))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            // Cache hit rate (cache feature only)
            if featureKey == "cache" && (pane.metrics.cacheHits + pane.metrics.cacheMisses) > 0 {
                drawerDivider

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("HIT RATE")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text(String(format: "%.0f%%", pane.metrics.cacheHitRate * 100))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.savingsGreen)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text("HITS / MISSES")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                        Text("\(pane.metrics.cacheHits) / \(pane.metrics.cacheMisses)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textPrimary)
                    }

                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }

            drawerDivider

            // How it works
            VStack(alignment: .leading, spacing: 3) {
                Text("HOW IT WORKS")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                Text(info.description)
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .padding(.bottom, 2)
        }
        .background(SenkaniTheme.paneBody.opacity(0.5))
    }

    private var drawerDivider: some View {
        Rectangle()
            .fill(SenkaniTheme.textTertiary.opacity(0.12))
            .frame(height: 0.5)
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1fM", Double(bytes) / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1fK", Double(bytes) / 1_000) }
        return "\(bytes)B"
    }
}
