import SwiftUI
import Core

/// Shows scheduled tasks with status, enable/disable toggles, and delete actions.
struct ScheduleView: View {
    @State private var tasks: [ScheduledTask] = []
    @State private var isLoading = true
    @State private var taskToDelete: ScheduledTask?
    @State private var showNewScheduleForm = false
    @State private var showPresetSheet = false

    // New schedule form fields
    @State private var newName = ""
    @State private var newSchedulePreset = "Daily"
    @State private var newCustomCron = ""
    @State private var newCommand = ""
    @State private var newBudgetLimit = ""
    @State private var createError: String?

    private let schedulePresets = ["Every hour", "Every 6 hours", "Daily", "Weekly", "Custom"]
    private func cronForPreset(_ preset: String) -> String {
        switch preset {
        case "Every hour": return "0 * * * *"
        case "Every 6 hours": return "0 */6 * * *"
        case "Daily": return "0 9 * * *"
        case "Weekly": return "0 9 * * 1"
        case "Custom": return newCustomCron
        default: return "0 9 * * *"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if showNewScheduleForm {
                newScheduleFormView
                Divider()
            }

            if isLoading {
                loadingView
            } else if tasks.isEmpty && !showNewScheduleForm {
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
                showPresetSheet = true
            } label: {
                Label("Install preset", systemImage: "square.stack.3d.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .sheet(isPresented: $showPresetSheet) {
                PresetInstallSheet(isPresented: $showPresetSheet, onInstalled: {
                    isLoading = true
                    loadTasks()
                })
            }

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showNewScheduleForm.toggle()
                    if showNewScheduleForm {
                        // Reset form fields
                        newName = ""
                        newSchedulePreset = "Daily"
                        newCustomCron = ""
                        newCommand = ""
                        newBudgetLimit = ""
                        createError = nil
                    }
                }
            } label: {
                Label(showNewScheduleForm ? "Cancel" : "New Schedule",
                      systemImage: showNewScheduleForm ? "xmark" : "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

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

                    // U.8 — when a schedule was registered from prose,
                    // surface the prose first and the compiled cron as
                    // a tooltip; cron-direct schedules display the
                    // human-readable cron as before.
                    if let prose = task.proseCadence, !prose.isEmpty {
                        Text(prose)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.controlBackgroundColor))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                            .help("Compiled cron: \(task.compiledCadence ?? task.cronPattern)")
                    } else if let counter = task.eventCounterCadence, !counter.isEmpty {
                        Text(counter)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                            .help("Counter cadence — fires from HookRouter, rate-limited to 1/min")
                    } else {
                        Text(CronToLaunchd.humanReadable(task.cronPattern))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(.controlBackgroundColor))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
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

    // MARK: - New Schedule Form

    private var newScheduleFormView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create New Schedule")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. daily-review", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                .frame(maxWidth: 200)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Schedule")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Picker("", selection: $newSchedulePreset) {
                        ForEach(schedulePresets, id: \.self) { Text($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }

                if newSchedulePreset == "Custom" {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cron Expression")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("0 9 * * 1-5", text: $newCustomCron)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(maxWidth: 160)
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. claude -p 'Review open PRs'", text: $newCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Budget Limit (cents, optional)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. 500", text: $newBudgetLimit)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
                .frame(maxWidth: 180)
            }

            HStack(spacing: 8) {
                Button {
                    createSchedule()
                } label: {
                    Label("Create", systemImage: "checkmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                          || newCommand.trimmingCharacters(in: .whitespaces).isEmpty)

                if let error = createError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }

                Spacer()

                // Preview the resolved cron
                let cron = cronForPreset(newSchedulePreset)
                if !cron.isEmpty {
                    Text(CronToLaunchd.humanReadable(cron))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color(.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
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
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No scheduled tasks")
                .font(.system(size: 14, weight: .medium))
            Text("Schedule recurring Claude tasks like\ncode reviews, dependency updates, or reports.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showNewScheduleForm = true
                }
            } label: {
                Label("Create Your First Schedule", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            Spacer()
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

    private func createSchedule() {
        let name = newName.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        let command = newCommand.trimmingCharacters(in: .whitespaces)
        let cron = cronForPreset(newSchedulePreset)

        guard !name.isEmpty else {
            createError = "Name is required"
            return
        }
        guard !command.isEmpty else {
            createError = "Command is required"
            return
        }
        guard !cron.isEmpty else {
            createError = "Schedule is required"
            return
        }
        if newSchedulePreset == "Custom" {
            guard CronToLaunchd.convert(cron) != nil else {
                createError = "Invalid cron expression"
                return
            }
        }

        let budget: Int? = newBudgetLimit.isEmpty ? nil : Int(newBudgetLimit)

        let task = ScheduledTask(
            name: name,
            cronPattern: cron,
            command: command,
            budgetLimitCents: budget,
            enabled: true
        )

        do {
            try ScheduleStore.save(task)
            withAnimation(.easeInOut(duration: 0.2)) {
                showNewScheduleForm = false
                createError = nil
            }
            loadTasks()
        } catch {
            createError = error.localizedDescription
        }
    }
}
