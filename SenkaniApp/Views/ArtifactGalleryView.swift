import SwiftUI
import AppKit
import Core

/// V.9b-1 — ArtifactGalleryView.
///
/// Split-pane SwiftUI surface for V.9a's `ArtifactStore`. List on
/// left; selected-artifact detail on right (metadata + lineage +
/// Reveal/Go-to-source buttons). Click-to-navigate routing is
/// delegated to `ArtifactGalleryRouter` (Core) so the contract is
/// testable from SenkaniTests; this view applies the returned
/// `ArtifactNavRoute` against the actual WorkspaceModel /
/// NSWorkspace surfaces.
///
/// Spec: spec/artifact_gallery.md, `## Gallery UI` section.
struct ArtifactGalleryView: View {
    let workspace: WorkspaceModel?

    @State private var records: [ArtifactRecord] = []
    @State private var selectedID: ArtifactID?
    @State private var revealedBody: ArtifactBody?
    @State private var showRevealSheet = false
    @State private var revealError: String?

    // V.9a entrypoint — composed with the three production providers.
    // Recorder wires to SessionDatabase.shared via Live recorder.
    private var store: ArtifactStore {
        ArtifactStore(
            providers: [
                PaneDiaryArtifactProvider(),
                SprintReviewArtifactProvider(),
                FilesystemArtifactProvider(),
            ],
            recorder: LiveArtifactAuditRecorder()
        )
    }

    private var fsProvider: FilesystemArtifactProvider {
        FilesystemArtifactProvider()
    }

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(minWidth: 320, idealWidth: 340, maxWidth: 360)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $showRevealSheet) {
            revealSheet
        }
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Artifacts")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(records.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if records.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(records, id: \.id.raw) { record in
                            listRow(record)
                                .background(
                                    selectedID == record.id
                                        ? Color.accentColor.opacity(0.15)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    navigate(record)
                                }
                                .onTapGesture(count: 1) {
                                    selectedID = record.id
                                    revealedBody = nil
                                    revealError = nil
                                }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Text("No artifacts yet.")
                .font(.system(size: 12, weight: .medium))
            Text("PaneDiary entries, SprintReview snapshots, and files in ~/.senkani/artifacts/ show up here as you work.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listRow(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            sourcePaneBadge(record.sourcePane)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(record.tags.sorted().prefix(3).joined(separator: " · "))
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    if record.redactionMarker != nil {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 6) {
                    Text("v\(record.version)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(relativeDate(record.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func sourcePaneBadge(_ pane: ArtifactSourcePane) -> some View {
        let label: String
        let color: Color
        switch pane {
        case .paneDiary:    label = "diary";    color = .blue
        case .sprintReview: label = "sprint";   color = .purple
        case .filesystem:   label = "file";     color = .green
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func relativeDate(_ d: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .abbreviated
        return fmt.localizedString(for: d, relativeTo: Date())
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let id = selectedID, let record = records.first(where: { $0.id == id }) {
            detailContent(record)
        } else {
            VStack {
                Spacer()
                Text("Select an artifact to inspect.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func detailContent(_ record: ArtifactRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                detailHeader(record)
                detailMetadata(record)
                lineageSection(record)
                detailActions(record)
                if let body = revealedBody {
                    bodyView(body)
                } else if let err = revealError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func detailHeader(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            sourcePaneBadge(record.sourcePane)
            Text(record.tags.sorted().joined(separator: " · "))
                .font(.system(size: 13, weight: .semibold))
            if record.redactionMarker != nil {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    private func detailMetadata(_ record: ArtifactRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            kv("id", record.id.raw)
            kv("version", "v\(record.version)")
            kv("created", record.createdAt.formatted(date: .abbreviated, time: .shortened))
            if let marker = record.redactionMarker {
                kv("redaction hits", "\(marker.hitCount) (\(marker.hitPatternNames.sorted().joined(separator: ", ")))")
            }
        }
        .font(.system(size: 11))
    }

    private func kv(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(key + ":")
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
            Spacer()
        }
    }

    @ViewBuilder
    private func lineageSection(_ record: ArtifactRecord) -> some View {
        let chain = store.versions(of: record.id)
        if !chain.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Lineage (\(chain.count))")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(chain, id: \.id.raw) { prev in
                    Button {
                        selectedID = prev.id
                        revealedBody = nil
                    } label: {
                        HStack(spacing: 6) {
                            Text("v\(prev.version)")
                                .font(.system(size: 10, weight: .semibold))
                            Text(relativeDate(prev.createdAt))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func detailActions(_ record: ArtifactRecord) -> some View {
        HStack(spacing: 8) {
            Button("Go to source") { navigate(record) }
            if record.redactionMarker != nil {
                Button("Reveal body") { showRevealSheet = true }
                    .tint(.orange)
            } else {
                Button("Read body") { readBody(record, allowSecrets: false) }
            }
            Spacer()
        }
        .buttonStyle(.bordered)
    }

    private func bodyView(_ body: ArtifactBody) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Body")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(body.utf8 ?? "<binary body, \(body.bytes.count) bytes>")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(8)
            }
            .frame(maxHeight: 280)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Reveal sheet

    private var revealSheet: some View {
        guard let id = selectedID, let record = records.first(where: { $0.id == id }),
              let marker = record.redactionMarker else {
            return AnyView(EmptyView())
        }
        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Reveal redacted body")
                    .font(.system(size: 14, weight: .semibold))
                Text(ArtifactGalleryRouter.revealSheetCopy(
                    sourcePane: marker.sourcePane,
                    hitCount: marker.hitCount))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { showRevealSheet = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Reveal and audit") {
                        showRevealSheet = false
                        readBody(record, allowSecrets: true)
                    }
                    .keyboardShortcut(.defaultAction)
                    .tint(.orange)
                }
            }
            .padding(20)
            .frame(width: 420)
        )
    }

    // MARK: - Actions

    private func refresh() {
        records = store.list(filter: .unconstrained)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func readBody(_ record: ArtifactRecord, allowSecrets: Bool) {
        let projectRoot = workspace?.activeProject?.path
        do {
            let body = try store.read(
                record.id,
                allowSecrets: allowSecrets,
                toolId: "artifactGallery",
                sessionId: nil,
                projectRoot: projectRoot
            )
            revealedBody = body
            revealError = nil
        } catch ArtifactReadError.secretsBlocked(let lane, let hitCount) {
            revealedBody = nil
            revealError = "Secrets blocked (lane: \(lane.rawValue), hits: \(hitCount)). Use Reveal body to override."
        } catch {
            revealedBody = nil
            revealError = "Read failed: \(error)"
        }
    }

    private func navigate(_ record: ArtifactRecord) {
        guard let route = ArtifactGalleryRouter.route(
            for: record,
            artifactsDirectory: fsProvider.artifactsDirectory
        ) else { return }

        switch route {
        case .openOrFocusPaneDiary(_, let paneSlug):
            guard let project = workspace?.activeProject else { return }
            if let match = project.panes.first(where: { $0.paneType.rawValue == paneSlug }) {
                workspace?.activePaneID = match.id
            } else if let type = PaneType(rawValue: paneSlug) {
                workspace?.addPane(type: type)
            }

        case .focusSprintReview:
            guard let project = workspace?.activeProject else { return }
            if let match = project.panes.first(where: { $0.paneType == .sprintReview }) {
                workspace?.activePaneID = match.id
            } else {
                workspace?.addPane(type: .sprintReview)
            }
            // Scroll-to-row binding follow-up — SprintReviewPane does
            // not currently expose a scroll-target API.

        case .revealInFinder(let absolutePath):
            let url = URL(fileURLWithPath: absolutePath)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }
}
