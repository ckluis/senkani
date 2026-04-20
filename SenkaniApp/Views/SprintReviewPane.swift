import SwiftUI
import Core

/// GUI counterpart to `senkani learn review` + the quarterly audit
/// surface. Lists staged compound-learning artifacts across all four
/// types (filter rule / context doc / instruction patch / workflow
/// playbook) for the configured window, with accept/reject per row,
/// plus a staleness section for applied artifacts that look stale.
///
/// Reads through `SprintReviewViewModel` (Core) — no new SQL, no new
/// persistence. Accept/reject route through the canonical
/// `CompoundLearning.apply*` / `LearnedRulesStore.reject*` paths.
struct SprintReviewPane: View {
    let workspace: WorkspaceModel?

    @State private var snapshot: SprintReviewSnapshot = SprintReviewSnapshot(
        sections: [], stalenessFlags: [],
        windowDays: SprintReviewViewModel.defaultWindowDays)
    @State private var windowDays: Int = SprintReviewViewModel.defaultWindowDays
    @State private var errorMessage: String?
    @State private var busyRowId: String?

    private var projectRoot: String {
        workspace?.activeProject?.path ?? FileManager.default.currentDirectoryPath
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if snapshot.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(snapshot.sections) { section in
                            sectionHeader(section.kind, count: section.rows.count)
                            ForEach(section.rows) { row in
                                rowView(row)
                            }
                        }
                        if !snapshot.stalenessFlags.isEmpty {
                            stalenessHeader
                            ForEach(snapshot.stalenessFlags) { flag in
                                stalenessRow(flag)
                            }
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 14)
                }
            }
            if let msg = errorMessage {
                errorBanner(msg)
            }
        }
        .background(SenkaniTheme.paneBody)
        .onAppear { reload() }
    }

    // MARK: - Subviews

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: SenkaniTheme.iconName(for: .sprintReview))
                .font(.system(size: 13))
                .foregroundStyle(SenkaniTheme.accentColor(for: .sprintReview))
            Text("Sprint Review")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textPrimary)
            Text("\(snapshot.totalCount) staged · \(snapshot.stalenessFlags.count) stale · \(windowDays)d window")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Spacer()
            windowStepper
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .help("Reload")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var windowStepper: some View {
        HStack(spacing: 4) {
            Button {
                windowDays = max(1, windowDays - 7)
                reload()
            } label: { Image(systemName: "minus.circle").font(.system(size: 10)) }
            .buttonStyle(.plain)
            Text("\(windowDays)d")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .frame(minWidth: 28, alignment: .center)
            Button {
                windowDays = min(120, windowDays + 7)
                reload()
            } label: { Image(systemName: "plus.circle").font(.system(size: 10)) }
            .buttonStyle(.plain)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 28))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("No staged proposals")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text("Staged artifacts surface once the daily sweep promotes them from `recurring`.")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sectionHeader(_ kind: SprintReviewArtifactKind, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(sectionLabel(kind).uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("(\(count))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func rowView(_ row: SprintReviewRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                Spacer()
                confidencePill(row.confidence)
                recurrencePill(row.recurrenceCount)
            }
            if !row.subtitle.isEmpty {
                Text(row.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Reject") {
                    performReject(row)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SenkaniTheme.inactiveBorder, lineWidth: 0.5))
                .disabled(busyRowId == row.id)

                Button("Accept") {
                    performAccept(row)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(SenkaniTheme.savingsGreen))
                .disabled(busyRowId == row.id)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SenkaniTheme.paneShell))
    }

    private var stalenessHeader: some View {
        HStack {
            Text("STALE APPLIED ARTIFACTS (\(snapshot.stalenessFlags.count))")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(SenkaniTheme.accentDiffViewer)
            Spacer()
        }
        .padding(.top, 12)
    }

    private func stalenessRow(_ flag: SprintReviewStalenessFlag) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(sectionLabel(flag.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.accentDiffViewer)
                Text("\(flag.idleDays)d idle")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Spacer()
                Button("Retire") {
                    performReject(rowId: flag.artifactId, kind: flag.kind)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(SenkaniTheme.inactiveBorder, lineWidth: 0.5))
            }
            Text(flag.note)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .lineLimit(2)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(SenkaniTheme.paneShell))
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .lineLimit(2)
            Spacer()
            Button {
                errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    private func confidencePill(_ value: Double) -> some View {
        Text(String(format: "%.2f", value))
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(SenkaniTheme.textSecondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(SenkaniTheme.paneBody))
    }

    private func recurrencePill(_ count: Int) -> some View {
        Text("×\(count)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(SenkaniTheme.textTertiary)
    }

    // MARK: - Actions

    private func reload() {
        LearnedRulesStore.reload()
        snapshot = SprintReviewViewModel.load(windowDays: windowDays)
    }

    private func performAccept(_ row: SprintReviewRow) {
        busyRowId = row.id
        defer { busyRowId = nil }
        do {
            try SprintReviewViewModel.accept(
                rowId: row.id, kind: row.kind, projectRoot: projectRoot)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = "Accept failed: \(error.localizedDescription)"
        }
    }

    private func performReject(_ row: SprintReviewRow) {
        performReject(rowId: row.id, kind: row.kind)
    }

    private func performReject(rowId: String, kind: SprintReviewArtifactKind) {
        busyRowId = rowId
        defer { busyRowId = nil }
        do {
            try SprintReviewViewModel.reject(rowId: rowId, kind: kind)
            errorMessage = nil
            reload()
        } catch {
            errorMessage = "Reject failed: \(error.localizedDescription)"
        }
    }

    private func sectionLabel(_ kind: SprintReviewArtifactKind) -> String {
        switch kind {
        case .filterRule: return "Filter rules"
        case .contextDoc: return "Context docs"
        case .instructionPatch: return "Instruction patches"
        case .workflowPlaybook: return "Workflow playbooks"
        }
    }
}
