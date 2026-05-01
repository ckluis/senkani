import SwiftUI
import Core

/// Side-by-side file diff viewer. V.12a: hunk-based render +
/// severity-tagged annotations sidebar with click-to-jump. The pane
/// computes LCS hunks once per (left, right) input pair and shows
/// each hunk as a labeled block; the sidebar lists all annotations
/// in the four-tag severity vocabulary (`must-fix` / `suggestion` /
/// `question` / `nit`) and a click on any annotation scrolls the
/// matching hunk into view.
struct DiffViewerPane: View {
    @Bindable var pane: PaneModel
    @State private var leftPath: String = ""
    @State private var rightPath: String = ""
    @State private var hunks: [DiffHunk] = []
    @State private var annotations: [DiffAnnotation] = []
    @State private var hasCompared = false
    @State private var scrollTarget: UUID?
    /// V.12b: subscribe to `HookAnnotationFeed.shared` once on appear.
    /// SwiftUI's `@State` survives view re-creation, so a single
    /// subscription persists across compare clicks. Multiple
    /// DiffViewerPane instances each add a subscriber — acceptable
    /// today (one diff pane is the common case); a future cleanup
    /// would centralize via a shared `@MainActor` controller.
    @State private var subscribedToHookFeed = false

    var body: some View {
        VStack(spacing: 0) {
            fileBar
            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            if !hasCompared {
                emptyState
            } else {
                HSplitView {
                    hunksColumn
                        .frame(minWidth: 320, idealWidth: 520)

                    annotationsSidebar
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 360)
                }
            }
        }
        .onAppear { subscribeIfNeeded() }
    }

    /// Subscribe to `HookAnnotationFeed.shared` exactly once. Each
    /// admitted `HookAnnotation` whose `filePath` matches `leftPath`
    /// or `rightPath` of an active comparison is converted into a
    /// `DiffAnnotation` pinned to the first hunk and appended to the
    /// sidebar. Conversions hop to the main actor before mutating
    /// `@State`.
    private func subscribeIfNeeded() {
        guard !subscribedToHookFeed else { return }
        subscribedToHookFeed = true
        HookAnnotationFeed.shared.subscribe { incoming in
            Task { @MainActor in
                if let converted = Self.convertToDiffAnnotation(
                    incoming,
                    leftPath: leftPath,
                    rightPath: rightPath,
                    hunks: hunks
                ) {
                    annotations.append(converted)
                }
            }
        }
    }

    /// Pure conversion helper — exposed `static` so unit tests can
    /// drive the path-match + first-hunk-pin logic without a SwiftUI
    /// view. Returns `nil` if no comparison is active, no hunks
    /// exist, or the annotation's `filePath` does not match either
    /// side of the active diff.
    static func convertToDiffAnnotation(
        _ hook: HookAnnotation,
        leftPath: String,
        rightPath: String,
        hunks: [DiffHunk]
    ) -> DiffAnnotation? {
        guard !hunks.isEmpty,
              let firstHunkId = hunks.first?.id,
              let path = hook.filePath,
              !path.isEmpty,
              path == leftPath || path == rightPath
        else { return nil }
        return DiffAnnotation(
            hunkId: firstHunkId,
            severity: hook.severity,
            body: hook.body,
            authoredBy: "hookrouter:\(hook.toolName)",
            createdAt: hook.createdAt
        )
    }

    // MARK: - File bar

    private var fileBar: some View {
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

            if hasCompared {
                Spacer()
                severityChipRow
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(SenkaniTheme.paneShell)
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

    private var severityChipRow: some View {
        let counts = DiffAnnotationLayout.severityCounts(annotations)
        return HStack(spacing: 4) {
            ForEach(DiffAnnotationSeverity.allCases, id: \.rawValue) { sev in
                severityChip(severity: sev, count: counts[sev] ?? 0)
            }
        }
    }

    private func severityChip(severity: DiffAnnotationSeverity, count: Int) -> some View {
        HStack(spacing: 3) {
            Image(systemName: severity.glyphName)
                .font(.system(size: 9))
            Text("\(count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(severity.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(severity.color.opacity(0.12))
        .cornerRadius(3)
        .help(severity.label)
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

    // MARK: - Hunks column

    private var hunksColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8, pinnedViews: []) {
                    if hunks.isEmpty {
                        Text("No differences.")
                            .font(.system(size: 11))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    } else {
                        ForEach(hunks) { hunk in
                            hunkBlock(hunk)
                                .id(hunk.id)
                        }
                    }
                }
                .padding(8)
            }
            .background(SenkaniTheme.paneBody)
            .onChange(of: scrollTarget) { _, target in
                if let target {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    scrollTarget = nil
                }
            }
        }
    }

    private func hunkBlock(_ hunk: DiffHunk) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("@@ -\(hunk.originalStartLine), +\(hunk.modifiedStartLine)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Spacer()
                Text("\(hunk.removedLines.count) − / \(hunk.addedLines.count) +")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(SenkaniTheme.paneShell)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(hunk.removedLines.enumerated()), id: \.offset) { idx, line in
                    diffLineRow(prefix: "−",
                                lineNo: hunk.originalStartLine + idx,
                                text: line,
                                background: Color.red.opacity(0.10))
                }
                ForEach(Array(hunk.addedLines.enumerated()), id: \.offset) { idx, line in
                    diffLineRow(prefix: "+",
                                lineNo: hunk.modifiedStartLine + idx,
                                text: line,
                                background: Color.green.opacity(0.10))
                }
            }
            .background(SenkaniTheme.paneBody)
        }
        .background(SenkaniTheme.paneShell.opacity(0.5))
        .cornerRadius(3)
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(SenkaniTheme.inactiveBorder, lineWidth: 0.5)
        )
    }

    private func diffLineRow(prefix: String, lineNo: Int, text: String, background: Color) -> some View {
        HStack(spacing: 0) {
            Text(prefix)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .frame(width: 14, alignment: .center)
            Text("\(lineNo)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 4)
        .background(background)
    }

    // MARK: - Annotations sidebar

    private var annotationsSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Annotations")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                Spacer()
                Text("\(annotations.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneShell)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let ordered = DiffAnnotationLayout.sidebarOrder(annotations, hunks: hunks)
                    if ordered.isEmpty {
                        Text("No annotations on these hunks.")
                            .font(.system(size: 10))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                            .padding(8)
                    } else {
                        ForEach(ordered) { ann in
                            annotationRow(ann)
                        }
                    }
                }
                .padding(8)
            }
            .background(SenkaniTheme.paneBody)
        }
        .background(SenkaniTheme.paneShell.opacity(0.4))
    }

    private func annotationRow(_ ann: DiffAnnotation) -> some View {
        Button(action: { scrollTarget = ann.hunkId }) {
            HStack(alignment: .top, spacing: 6) {
                severityBadge(ann.severity)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ann.body.isEmpty ? "(empty)" : ann.body)
                        .font(.system(size: 10))
                        .foregroundStyle(SenkaniTheme.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text(ann.authoredBy)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(SenkaniTheme.paneBody)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(ann.severity.color.opacity(0.4), lineWidth: 0.5)
            )
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help("Click to jump to hunk")
    }

    private func severityBadge(_ sev: DiffAnnotationSeverity) -> some View {
        HStack(spacing: 3) {
            Image(systemName: sev.glyphName)
                .font(.system(size: 9))
            Text(sev.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(sev.color)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(sev.color.opacity(0.15))
        .cornerRadius(2)
    }

    // MARK: - Diff run

    private func runDiff() {
        let left = (try? String(contentsOfFile: leftPath, encoding: .utf8)) ?? ""
        let right = (try? String(contentsOfFile: rightPath, encoding: .utf8)) ?? ""
        hunks = DiffEngine.computeHunks(original: left, modified: right)
        // V.12a round 1 ships rendering surface only — annotations stay
        // empty until V.12b wires HookRouter denials in. Operators can
        // still verify the pane by injecting fixture annotations via a
        // future #DEBUG hook; tests cover the layout helpers directly.
        annotations = []
        hasCompared = true
    }
}

// MARK: - Severity color tokens

extension DiffAnnotationSeverity {
    /// Theme-routed color for the severity badge. Frozen mapping —
    /// must-fix is always red, suggestion blue, question yellow, nit
    /// cyan. Documented at the type definition; keep in sync.
    @MainActor
    var color: Color {
        switch self {
        case .mustFix:    return ThemeEngine.shared.ansiRed
        case .suggestion: return ThemeEngine.shared.ansiBlue
        case .question:   return ThemeEngine.shared.ansiYellow
        case .nit:        return ThemeEngine.shared.ansiCyan
        }
    }
}
