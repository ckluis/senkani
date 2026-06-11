import SwiftUI
import Core

/// Settings → Notifications matrix
/// (item `t6-settings-notifications-matrix-ui-2026-05-21`).
///
/// Operator-facing pane that edits `~/.senkani/notifications.json`
/// without hand-editing JSON: a per-sink × per-event grid of
/// checkboxes over `NotificationRouter.Config`. Every cell read/flip
/// funnels through the headless `NotificationMatrix` helper (Core), so
/// the semantics are CI-tested; this view is presentation + disk I/O
/// + the live-reload hand-off only.
///
/// **Live reload.** A successful save calls
/// `NotificationBootstrap.bootstrap(configPath:)` again — the second
/// `NotificationDelivery.install` replaces the prior router, so
/// subsequent `NotifyEvent` fires honor the new matrix without
/// restarting the App.
///
/// **Failure surfacing.** `Config.save(to:)` throws (unlike the
/// lenient read path) — a failed write shows an inline error and the
/// matrix stays on the last state that actually reached disk, so the
/// checkboxes never lie about what the router will reload.
struct NotificationsSettingsView: View {
    /// Test/preview seam — production reads the bootstrap default
    /// (`~/.senkani/notifications.json`).
    var configPath: String = NotificationBootstrap.defaultConfigPath()

    @State private var config = NotificationRouter.Config(sinks: [:])
    @State private var saveError: String?
    @State private var lastTestFireNote: String?

    /// Rows: production-registered sinks first (the bootstrap's
    /// registry), then any extra sinks found in the config file.
    private var sinkNames: [String] {
        NotificationMatrix.displaySinks(
            config: config,
            knownSinks: NotificationBootstrap.registeredSinkNames
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    explainer
                    matrixGrid
                    if let saveError {
                        errorBanner(saveError)
                    }
                    testFireSection
                    pathFooter
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(SenkaniTheme.paneBody)
        .onAppear { reload() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell.badge")
                .foregroundStyle(.orange)
            Text("Notifications")
                .font(.title2.weight(.semibold))
            Spacer()
            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Re-read \(configPath) from disk")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var explainer: some View {
        Text("Pick which sinks receive which event classes. A sink with no entry in the config file subscribes to everything (opt-out, not opt-in — under-notification hides failures). Every change is written to disk immediately and the live router reloads without restarting the app. A ConfirmationGate deny always surfaces regardless of this matrix (the non-suppressible failure path).")
            .font(.system(size: 11))
            .foregroundStyle(SenkaniTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Matrix

    private var matrixGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 10) {
            GridRow {
                Text("Sink")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SenkaniTheme.textTertiary)
                ForEach(NotificationRouter.EventKind.allCases, id: \.rawValue) { kind in
                    Text(Self.columnTitle(for: kind))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(SenkaniTheme.textTertiary)
                        .help(kind.rawValue)
                }
            }

            Divider()

            ForEach(sinkNames, id: \.self) { sink in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.displayName(for: sink))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(SenkaniTheme.textPrimary)
                        Text(sink)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(SenkaniTheme.textTertiary)
                    }

                    ForEach(NotificationRouter.EventKind.allCases, id: \.rawValue) { kind in
                        Toggle("", isOn: matrixBinding(sink: sink, event: kind))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .help("\(sink) ← \(kind.rawValue)")
                    }
                }
            }
        }
        .padding(12)
        .background(SenkaniTheme.paneShell)
        .cornerRadius(6)
    }

    /// One checkbox = one matrix cell. The getter mirrors exactly what
    /// `NotificationRouter.make` would resolve for this cell; the
    /// setter routes through the single toggle funnel below.
    private func matrixBinding(
        sink: String,
        event: NotificationRouter.EventKind
    ) -> Binding<Bool> {
        Binding(
            get: { NotificationMatrix.isEnabled(config, sink: sink, event: event) },
            set: { _ in toggleCell(sink: sink, event: event) }
        )
    }

    /// Flip one cell: write the JSON, then live-reload the router.
    /// On a failed write the in-memory state is NOT advanced — the
    /// matrix keeps showing what is actually on disk.
    private func toggleCell(sink: String, event: NotificationRouter.EventKind) {
        let updated = NotificationMatrix.toggled(config, sink: sink, event: event)
        do {
            try ensureParentDirectoryExists()
            try updated.save(to: configPath)
            config = updated
            saveError = nil
            // Live reload — the second install replaces the prior
            // router, so the next NotifyEvent honors the new matrix.
            NotificationBootstrap.bootstrap(configPath: configPath)
        } catch {
            saveError = "Couldn't write \(configPath): \(error.localizedDescription)"
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textPrimary)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Test fire (debug affordance)

    /// Debug affordance from the item's acceptance: fire a synthetic
    /// event through the LIVE router so the operator can verify the
    /// matrix end-to-end — a subscribed `stdout` logs a JSON line, a
    /// subscribed `macos_local` posts a banner (if TCC-authorized).
    private var testFireSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Test")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("Fire a synthetic event through the live router. Sinks ticked above for that class should react; unticked sinks stay silent.")
                .font(.system(size: 10))
                .foregroundStyle(SenkaniTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Fire done") {
                    fireTest(.notifyDone(
                        toolName: "matrix-test",
                        summary: "Synthetic notify_done from Settings → Notifications"))
                }
                Button("Fire failure") {
                    fireTest(.notifyFailure(
                        toolName: "matrix-test",
                        reason: "Synthetic notify_failure from Settings → Notifications"))
                }
                Button("Fire schedule end") {
                    fireTest(.scheduleEnd(
                        scheduleId: "matrix-test",
                        summary: "Synthetic schedule_end from Settings → Notifications"))
                }
            }
            .controlSize(.small)
            if let lastTestFireNote {
                Text(lastTestFireNote)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
        }
    }

    private func fireTest(_ event: NotifyEvent) {
        NotificationDelivery.deliver(event)
        let kind = NotificationRouter.EventKind.of(event).rawValue
        lastTestFireNote = "delivered \(kind) via the live router"
    }

    // MARK: - Footer

    private var pathFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Config file:")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text(configPath)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
                .textSelection(.enabled)
            Text("Delete the file to restore the default (every sink subscribes to every event).")
                .font(.system(size: 9))
                .foregroundStyle(SenkaniTheme.textTertiary)
        }
    }

    // MARK: - Disk

    private func reload() {
        config = NotificationRouter.loadConfig(from: configPath)
            ?? NotificationRouter.Config(sinks: [:])
        saveError = nil
    }

    private func ensureParentDirectoryExists() throws {
        let dir = (configPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
    }

    // MARK: - Labels

    static func displayName(for sink: String) -> String {
        switch sink {
        case "stdout": return "Stdout (JSON log line)"
        case "macos_local": return "macOS banner"
        default: return sink
        }
    }

    static func columnTitle(for kind: NotificationRouter.EventKind) -> String {
        switch kind {
        case .notifyDone: return "Done"
        case .notifyFailure: return "Failure"
        case .scheduleEnd: return "Schedule end"
        }
    }
}
