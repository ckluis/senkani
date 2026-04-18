import SwiftUI
import Core

/// Side-by-side file diff viewer. Drop two files or paste paths to compare.
/// Highlights added (green) and removed (red) lines.
struct DiffViewerPane: View {
    @Bindable var pane: PaneModel
    @State private var leftPath: String = ""
    @State private var rightPath: String = ""
    @State private var leftLines: [DiffLine] = []
    @State private var rightLines: [DiffLine] = []
    @State private var hasCompared = false

    var body: some View {
        VStack(spacing: 0) {
            // File picker bar
            HStack(spacing: 8) {
                fileField(label: "Original", text: $leftPath)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                fileField(label: "Modified", text: $rightPath)

                Button("Compare") { runDiff() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(leftPath.isEmpty || rightPath.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(SenkaniTheme.paneShell)

            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            if !hasCompared {
                emptyState
            } else {
                HStack(spacing: 0) {
                    diffColumn(lines: leftLines, label: "Original")
                    Rectangle().fill(SenkaniTheme.inactiveBorder).frame(width: 0.5)
                    diffColumn(lines: rightLines, label: "Modified")
                }
            }
        }
    }

    private func fileField(label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(SenkaniTheme.textTertiary)
            TextField("path...", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(SenkaniTheme.paneBody)
                .cornerRadius(3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 32))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("Enter two file paths and click Compare")
                .font(.system(size: 12))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SenkaniTheme.paneBody)
    }

    private func diffColumn(lines: [DiffLine], label: String) -> some View {
        VStack(spacing: 0) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(SenkaniTheme.paneShell)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        HStack(spacing: 0) {
                            Text("\(idx + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                                .frame(width: 32, alignment: .trailing)
                                .padding(.trailing, 6)

                            Text(line.text)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 1)
                        .padding(.horizontal, 4)
                        .background(backgroundColor(for: line.kind))
                    }
                }
            }
            .background(SenkaniTheme.paneBody)
        }
    }

    private func backgroundColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .unchanged: return .clear
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        }
    }

    private func runDiff() {
        let left = (try? String(contentsOfFile: leftPath, encoding: .utf8)) ?? ""
        let right = (try? String(contentsOfFile: rightPath, encoding: .utf8)) ?? ""

        let paired = DiffEngine.computePairedLines(original: left, modified: right)
        leftLines = paired.left
        rightLines = paired.right
        hasCompared = true
    }
}
