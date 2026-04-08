import SwiftUI

/// Configuration sheet shown before launching Claude Code.
/// Lets the user pick permission level, model effort, and see the final command.
struct ClaudeLaunchSheet: View {
    let onLaunch: (String) -> Void  // passes the full claude command string

    @Environment(\.dismiss) private var dismiss
    @State private var permissionMode: PermissionMode = .normal
    @State private var modelEffort: ModelEffort = .high

    enum PermissionMode: String, CaseIterable {
        case normal = "Normal"
        case autoAccept = "Auto-accept"
        case plan = "Plan only"

        var flag: String {
            switch self {
            case .normal: return ""
            case .autoAccept: return " --dangerously-skip-permissions"
            case .plan: return " --allowedTools ''"
            }
        }

        var description: String {
            switch self {
            case .normal: return "Asks before file edits and commands"
            case .autoAccept: return "Approves all tool use automatically"
            case .plan: return "Read-only — can explore but not modify"
            }
        }

        var icon: String {
            switch self {
            case .normal: return "shield.checkered"
            case .autoAccept: return "bolt.shield"
            case .plan: return "eye"
            }
        }
    }

    enum ModelEffort: String, CaseIterable {
        case low = "Low"
        case medium = "Medium"
        case high = "High"

        var description: String {
            switch self {
            case .low: return "Fast, cheaper — good for simple tasks"
            case .medium: return "Balanced speed and quality"
            case .high: return "Maximum quality — best for complex work"
            }
        }
    }

    var claudeCommand: String {
        var cmd = "claude"
        if modelEffort != .high {
            cmd += " --model sonnet"
        }
        cmd += permissionMode.flag
        return cmd
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 18))
                    .foregroundStyle(.blue)
                Text("Launch Claude Code")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Permission mode
            VStack(alignment: .leading, spacing: 8) {
                Text("PERMISSION MODE")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .tracking(1.0)

                ForEach(PermissionMode.allCases, id: \.self) { mode in
                    optionRow(
                        icon: mode.icon,
                        title: mode.rawValue,
                        description: mode.description,
                        isSelected: permissionMode == mode
                    ) {
                        permissionMode = mode
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Model effort
            VStack(alignment: .leading, spacing: 8) {
                Text("MODEL EFFORT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .tracking(1.0)

                ForEach(ModelEffort.allCases, id: \.self) { effort in
                    optionRow(
                        icon: effort == .high ? "flame" : effort == .medium ? "gauge.with.dots.needle.50percent" : "hare",
                        title: effort.rawValue,
                        description: effort.description,
                        isSelected: modelEffort == effort
                    ) {
                        modelEffort = effort
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            // Command preview
            VStack(alignment: .leading, spacing: 4) {
                Text("COMMAND")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .tracking(1.0)

                Text(claudeCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SenkaniTheme.paneBody)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            // Launch button
            Button {
                onLaunch(claudeCommand)
                dismiss()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                    Text("Launch")
                        .font(.system(size: 13, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .keyboardShortcut(.return)
        }
        .frame(width: 380)
        .background(SenkaniTheme.paneShell)
    }

    private func optionRow(icon: String, title: String, description: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? .blue : SenkaniTheme.textTertiary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(SenkaniTheme.textPrimary)
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textSecondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
