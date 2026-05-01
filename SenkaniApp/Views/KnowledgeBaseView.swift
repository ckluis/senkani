import SwiftUI
import Core
import MCPServer

/// KB entity browser. Primary view for PaneType.knowledgeBase.
/// Navigation: entity list → entity detail (back returns to list).
/// Auto-refreshes entity list every 2s via Timer (suppressed when editing).
/// Auto-saves understanding on deselect/back.
struct KnowledgeBaseView: View {
    @State private var vm = KBPaneViewModel()

    var body: some View {
        Group {
            if vm.selectedEntity == nil {
                entityListView
            } else {
                entityDetailView
            }
        }
        .background(SenkaniTheme.paneBody)
        .onAppear { vm.loadEntities(); vm.loadSessionBrief() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            if !vm.isDirty { vm.loadEntities() }
        }
        // V.5b — surfaces the AuthorshipTag prompt when a save is
        // queued but the row's prior tag is `.unset` or `nil`. Sheet
        // calls back into the VM to resolve or skip.
        .sheet(isPresented: $vm.pendingAuthorshipPrompt) {
            AuthorshipPromptSheet(
                onChoice: { tag in vm.resolveAuthorship(tag) },
                onSkip:   { vm.skipAuthorship() }
            )
        }
    }

    // MARK: - Entity List

    private var entityListView: some View {
        VStack(spacing: 0) {
            // Toolbar: search + sort + badge
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                TextField("Filter entities...", text: $vm.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(SenkaniTheme.textPrimary)

                if !vm.searchQuery.isEmpty {
                    Button { vm.searchQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Menu {
                    Button("Mentions")  { vm.sortMode = .mentionCountDesc; vm.loadEntities() }
                    Button("Name")      { vm.sortMode = .nameAsc;          vm.loadEntities() }
                    Button("Staleness") { vm.sortMode = .stalenessDesc;    vm.loadEntities() }
                    Button("Recent")    { vm.sortMode = .lastEnrichedDesc; vm.loadEntities() }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if vm.enrichmentBadge > 0 {
                    Text("\(vm.enrichmentBadge)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.orange))
                        .help("\(vm.enrichmentBadge) enrichment candidate(s)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SenkaniTheme.paneShell)

            Divider().overlay(SenkaniTheme.inactiveBorder)

            // Session brief (only when prior session data exists)
            if let activity = vm.sessionBriefActivity {
                VStack(spacing: 0) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.1)) {
                            vm.isSessionBriefExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                            Text(briefSummaryLine(activity))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                            Spacer()
                            Image(systemName: vm.isSessionBriefExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8))
                                .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.5))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)

                    if vm.isSessionBriefExpanded {
                        VStack(alignment: .leading, spacing: 3) {
                            let filenames = activity.topHotFiles.prefix(3)
                                .map { ($0 as NSString).lastPathComponent }
                            if !filenames.isEmpty {
                                Text("Hot: \(filenames.joined(separator: ", "))")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.7))
                            }
                            if let cmd = activity.lastCommand {
                                let truncated = cmd.count > 55 ? String(cmd.prefix(52)) + "…" : cmd
                                Text("Last: \(truncated)")
                                    .font(.system(size: 8, design: .monospaced))
                                    .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 5)
                    }

                    Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.4))
                }
                .background(SenkaniTheme.paneShell.opacity(0.4))
            }

            if vm.displayEntities.isEmpty {
                emptyListState
            } else {
                HStack {
                    Text("\(vm.entities.count) entit\(vm.entities.count == 1 ? "y" : "ies")")
                        .font(.system(size: 9))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(vm.displayEntities, id: \.id) { entity in
                            entityRow(entity)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
    }

    private func entityRow(_ entity: KnowledgeEntity) -> some View {
        Button { vm.select(entity) } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(typeColor(entity.entityType))
                    .frame(width: 5, height: 5)

                Text(entity.name)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                    .lineLimit(1)

                Spacer()

                Text(entity.entityType)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(typeColor(entity.entityType).opacity(0.12)))

                AuthorshipBadgeView(tag: entity.authorship, context: .knowledgeBase)

                Text("\(entity.mentionCount)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(entity.mentionCount > 0
                        ? SenkaniTheme.accentKnowledgeBase
                        : SenkaniTheme.textTertiary)
                    .frame(minWidth: 18, alignment: .trailing)

                if vm.enrichmentBadge > 0,
                   KBReader.tracker.state().enrichmentCandidates.contains(entity.name) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 7))
                    .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.4))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(SenkaniTheme.paneShell.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var emptyListState: some View {
        let guidance = EmptyStateGuidance.entry(for: .knowledgeBase)
        return VStack(spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.system(size: 28))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text(guidance.headline)
                .font(.subheadline)
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text(guidance.populatingEvent)
                .font(.caption)
                .foregroundStyle(SenkaniTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Text(guidance.nextAction)
                .font(.caption.weight(.medium))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(guidance.headline). \(guidance.populatingEvent) \(guidance.nextAction)"))
    }

    // MARK: - Entity Detail

    @ViewBuilder
    private var entityDetailView: some View {
        if let entity = vm.selectedEntity {
            VStack(spacing: 0) {
                // Nav header
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { vm.deselect() }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 9, weight: .semibold))
                            Text("Back")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(SenkaniTheme.accentKnowledgeBase)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if vm.isDirty {
                        HStack(spacing: 3) {
                            Circle().fill(.orange).frame(width: 5, height: 5)
                            Text("unsaved")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                        }
                    }
                    if vm.isSaving {
                        Text("saving…")
                            .font(.system(size: 9))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }

                    Text(entity.entityType)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(typeColor(entity.entityType).opacity(0.15)))

                    AuthorshipBadgeView(tag: entity.authorship, context: .knowledgeBase)

                    Button {
                        if vm.showingGraph {
                            vm.showingGraph = false
                        } else {
                            vm.showingGraph = true
                            vm.loadGraph(for: entity)
                        }
                    } label: {
                        Image(systemName: vm.showingGraph ? "list.bullet" : "circle.hexagongrid")
                            .font(.system(size: 9))
                            .foregroundStyle(vm.showingGraph
                                ? SenkaniTheme.accentKnowledgeBase
                                : SenkaniTheme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help(vm.showingGraph ? "Show detail" : "Show relations graph")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(SenkaniTheme.paneShell)

                Divider().overlay(SenkaniTheme.inactiveBorder)

                if vm.showingGraph {
                    if vm.isLoadingGraph {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        RelationsGraphView(
                            nodes: vm.graphNodes,
                            edges: vm.graphEdges,
                            selectedEntityName: entity.name
                        ) { targetName in
                            if let target = KBReader.store.entity(named: targetName) {
                                withAnimation(.easeInOut(duration: 0.12)) { vm.select(target) }
                            }
                        }
                    }
                } else {

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(entity.name)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textPrimary)

                        HStack(spacing: 10) {
                            metricChip("mentions", "\(entity.mentionCount)")
                            if let le = entity.lastEnriched {
                                metricChip("enriched", shortDate(le))
                            }
                            if let sp = entity.sourcePath {
                                metricChip("src", (sp as NSString).lastPathComponent)
                            }
                        }

                        Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.5))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("UNDERSTANDING")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(SenkaniTheme.textTertiary)
                                .tracking(1.0)

                            TextEditor(text: $vm.understandingText)
                                .font(.system(size: 11))
                                .scrollContentBackground(.hidden)
                                .background(SenkaniTheme.paneBody)
                                .frame(minHeight: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(SenkaniTheme.inactiveBorder.opacity(0.4), lineWidth: 0.5)
                                )
                                .onChange(of: vm.understandingText) { _, new in
                                    vm.isDirty = true
                                    vm.updateCompletion(new)
                                }

                            if !vm.completionCandidates.isEmpty {
                                VStack(alignment: .leading, spacing: 1) {
                                    ForEach(vm.completionCandidates, id: \.self) { candidate in
                                        Button {
                                            vm.understandingText = WikiLinkHelpers.applyCompletion(
                                                candidate, to: vm.understandingText
                                            )
                                            vm.completionCandidates = []
                                        } label: {
                                            Text("[[\(candidate)]]")
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(SenkaniTheme.accentKnowledgeBase)
                                                .padding(.horizontal, 8).padding(.vertical, 3)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        .buttonStyle(.plain)
                                        .background(SenkaniTheme.paneShell.opacity(0.7))
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(SenkaniTheme.inactiveBorder.opacity(0.5), lineWidth: 0.5))
                            }
                        }

                        if let staged = vm.stagedProposal {
                            Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.5))

                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 6) {
                                    Circle().fill(.orange).frame(width: 5, height: 5)
                                    Text("PROPOSAL PENDING")
                                        .font(.system(size: 8, weight: .semibold))
                                        .foregroundStyle(.orange)
                                        .tracking(1.0)
                                    Spacer()
                                    Button("Accept") {
                                        withAnimation(.easeInOut(duration: 0.12)) { vm.acceptProposal() }
                                    }
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(.orange))
                                    .buttonStyle(.plain)

                                    Button("Discard") {
                                        withAnimation(.easeInOut(duration: 0.12)) { vm.discardProposal() }
                                    }
                                    .font(.system(size: 9))
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                                    .buttonStyle(.plain)
                                }

                                Text(extractProposedUnderstanding(staged))
                                    .font(.system(size: 10))
                                    .foregroundStyle(SenkaniTheme.textSecondary)
                                    .lineLimit(4)
                                    .padding(6)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(SenkaniTheme.paneShell))
                            }
                        }

                        if !vm.detailLinks.isEmpty {
                            Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.5))

                            VStack(alignment: .leading, spacing: 6) {
                                Text("RELATIONS (\(vm.detailLinks.count))")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                                    .tracking(1.0)

                                ForEach(vm.detailLinks, id: \.id) { link in
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.right")
                                            .font(.system(size: 8))
                                            .foregroundStyle(SenkaniTheme.accentKnowledgeBase)
                                        Text(link.relation ?? "related_to")
                                            .font(.system(size: 9, design: .monospaced))
                                            .foregroundStyle(SenkaniTheme.textTertiary)
                                        Text(link.targetName)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(SenkaniTheme.textSecondary)
                                    }
                                }
                            }
                        }

                        if !vm.detailDecisions.isEmpty {
                            Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.5))

                            VStack(alignment: .leading, spacing: 8) {
                                Text("DECISIONS (\(vm.detailDecisions.count))")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                                    .tracking(1.0)

                                ForEach(vm.detailDecisions, id: \.id) { dec in
                                    decisionRow(dec)
                                }
                            }
                        }

                        if !vm.detailCouplings.isEmpty {
                            Divider().overlay(SenkaniTheme.inactiveBorder.opacity(0.5))

                            VStack(alignment: .leading, spacing: 6) {
                                Text("CO-CHANGES (\(vm.detailCouplings.count))")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(SenkaniTheme.textTertiary)
                                    .tracking(1.0)

                                ForEach(vm.detailCouplings, id: \.id) { entry in
                                    couplingRow(entry, entityName: vm.selectedEntity?.name ?? "")
                                }
                            }
                        }
                    }
                    .padding(12)
                }
                } // end else (detail scroll view)
            }
        }
    }

    // MARK: - Helpers

    private func decisionRow(_ dec: DecisionRecord) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(shortDate(dec.createdAt))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                Text(dec.decision)
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Text(dec.source == "git_commit" ? "git" : dec.source)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(decisionSourceColor(dec.source))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(decisionSourceColor(dec.source).opacity(0.12)))
            }
            if !dec.rationale.isEmpty {
                Text("because \(dec.rationale)")
                    .font(.system(size: 9))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                    .padding(.leading, 6)
            }
            if let vu = dec.validUntil {
                Text(vu > Date() ? "expires \(shortDate(vu))" : "expired \(shortDate(vu))")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(vu > Date() ? .orange.opacity(0.7) : SenkaniTheme.textTertiary.opacity(0.4))
                    .padding(.leading, 6)
            }
        }
    }

    private func couplingRow(_ entry: CouplingEntry, entityName: String) -> some View {
        let partner = entry.entityA == entityName ? entry.entityB : entry.entityA
        let pct = Int(entry.couplingScore * 100)
        return HStack(spacing: 6) {
            Text(partner)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .lineLimit(1)
            Spacer()
            Text("\(entry.commitCount)/\(entry.totalCommits)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("\(pct)%")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(couplingColor(entry.couplingScore))
        }
    }

    private func couplingColor(_ score: Double) -> Color {
        if score >= 0.7 { return .red.opacity(0.8) }
        if score >= 0.4 { return .orange.opacity(0.9) }
        return SenkaniTheme.textSecondary
    }

    private func decisionSourceColor(_ source: String) -> Color {
        switch source {
        case "git_commit": return .blue.opacity(0.8)
        case "agent":      return .orange.opacity(0.8)
        case "cli":        return SenkaniTheme.accentTerminal
        default:           return SenkaniTheme.textTertiary
        }
    }

    private func typeColor(_ type: String) -> Color {
        switch type {
        case "class":   return SenkaniTheme.accentKnowledgeBase
        case "struct":  return SenkaniTheme.accentTerminal
        case "func":    return SenkaniTheme.accentPreview
        case "file":    return .purple.opacity(0.8)
        default:        return SenkaniTheme.textSecondary
        }
    }

    private func metricChip(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text(value)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(SenkaniTheme.paneShell))
    }

    private func extractProposedUnderstanding(_ markdown: String) -> String {
        if let content = KnowledgeParser.parse(markdown), !content.compiledUnderstanding.isEmpty {
            return content.compiledUnderstanding
        }
        return String(markdown.prefix(200))
    }

    private func briefSummaryLine(_ activity: SessionDatabase.LastSessionActivity) -> String {
        let mins = Int(activity.durationSeconds / 60)
        let dur = mins > 0 ? "\(mins)m" : "<1m"
        let savings = activity.totalRawTokens > 0
            ? Int(Double(activity.totalSavedTokens) / Double(activity.totalRawTokens) * 100)
            : 0
        return "\(dur) · \(activity.commandCount) calls · \(savings)% savings"
    }

    private func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}
