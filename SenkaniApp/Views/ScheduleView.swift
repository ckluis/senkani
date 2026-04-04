import SwiftUI
import Core

/// Shows scheduled tasks with status, enable/disable toggles, and delete actions.
struct ScheduleView: View {
    @State private var tasks: [ScheduledTask] = []
    @State private var isLoading = true
    @State private var taskToDelete: ScheduledTask?

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if isLoading {
                loadingView
            } else if tasks.isEmpty {
                emptyView
            } else {
                taskListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .task {
            loadTasks()
        }
        .alert("Remove Schedule", isPresented: .init(
            get: { taskToDelete != nil },
            set: { if !$0 { taskToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) { taskToDelete = nil }
            Button("Remove", role: .destructive) {
                if let task = taskToDelete {
                    removeTask(task)
                }
            }
        } message: {
            if let task = taskToDelete {
                Text("Remove \"\(task.name)\"? This will unload the launchd job and delete the config.")
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Schedules")
                    .font(.system(size: 18, weight: .semibold))
                Text("\(tasks.count) task\(tasks.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                isLoading = true
                loadTasks()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Task List

    private var taskListView: some View {
        List {
            ForEach(tasks) { task in
                taskRow(task)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }

    private func taskRow(_ task: ScheduledTask) -> some View {
        HStack(spacing: 12) {
            // Status badge
            statusBadge(task)

            // Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(task.name)
                        .font(.system(size: 13, weight: .semibold))

                    Text(CronToLaunchd.humanReadable(task.cronPattern))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(Capsule())
                        .foregroundStyle(.secondary)
                }

                Text(task.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let lastRun = task.lastRunAt {
                    Text("Last run: \(lastRun, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            // Enable/disable toggle
            Toggle("", isOn: Binding(
                get: { task.enabled },
                set: { newValue in toggleTask(task, enabled: newValue) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(task.enabled ? "Disable this schedule" : "Enable this schedule")

            // Delete button
            Button {
                taskToDelete = task
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove this schedule")
        }
        .padding(.vertical, 4)
    }

    private func statusBadge(_ task: ScheduledTask) -> some View {
        let (color, icon) = statusInfo(task)
        return Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(color)
            .frame(width: 24)
            .help(task.lastRunResult ?? "Never run")
    }

    private func statusInfo(_ task: ScheduledTask) -> (Color, String) {
        guard let result = task.lastRunResult else {
            return (.gray, "circle.dotted")
        }
        if result == "success" {
            return (.green, "checkmark.circle.fill")
        }
        if result == "budget_exceeded" {
            return (.yellow, "exclamationmark.triangle.fill")
        }
        return (.red, "xmark.circle.fill")
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Loading schedules...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No scheduled tasks")
                .font(.system(size: 14, weight: .medium))
            Text("Use `senkani schedule create` to add one.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func loadTasks() {
        tasks = ScheduleStore.list()
        isLoading = false
    }

    private func toggleTask(_ task: ScheduledTask, enabled: Bool) {
        var updated = task
        updated.enabled = enabled
        try? ScheduleStore.save(updated)
        loadTasks()
    }

    private func removeTask(_ task: ScheduledTask) {
        try? ScheduleStore.remove(task.name)
        taskToDelete = nil
        loadTasks()
    }
}
