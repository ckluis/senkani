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

    // U.x a-1 — compose modes. The create-form supports three ways to
    // express a cadence, mirroring the `senkani schedule create` CLI
    // (`--cron` / `--prose` / `--counter-cadence`). Each mode resolves
    // to either a cron string (cron + prose) or a CounterCadence
    // (counter); the AmplificationGuard verdict + CronPreview next-fires
    // + Create gating are all derived live from the composed cadence.
    @State private var composeMode: ComposeMode = .cron
    @State private var newProse = ""
    @State private var newCounter = ""
    /// Cron compiled from `newProse` by the async prose compiler. nil
    /// until a compile succeeds; the only resolvable-cron source in
    /// prose mode, so Create stays disabled while nil.
    @State private var compiledProseCron: String?
    /// Operator-facing inline error when a prose phrase needs the MLX
    /// fallback and it is unavailable (rule-arm handles the common case).
    @State private var proseError: String?
    /// Cancellable handle for the in-flight prose compile.
    @State private var proseCompileTask: Task<Void, Never>?
    /// Explicit override allowing an `.amplification` schedule through
    /// the Create gate (the operator accepts the risk).
    @State private var overrideAmplification = false

    // U.x a-2 — edit-in-place. When the operator picks an existing row the
    // compose surface opens PREFILLED with that schedule's current cadence;
    // saving UPDATES the same JSON file (the name is the id, so a re-save
    // overwrites it) through the exact same compile + AmplificationGuard +
    // gating path the create flow uses. `editingName` non-nil means the
    // form is editing rather than creating.
    @State private var editingName: String?

    /// Three ways to compose a new schedule's cadence.
    private enum ComposeMode: String, CaseIterable, Identifiable {
        case prose = "Prose"
        case counter = "Counter"
        case cron = "Cron"
        var id: String { rawValue }
    }

    /// App-side prose compiler: deterministic rule arm + Null MLX arm.
    /// The rule arm resolves common phrases ("every weekday at 9am") in
    /// process with no model; phrases that would need MLX throw
    /// `.unavailable`, which surfaces as an inline error (the app does
    /// not link the CLI's subprocess MLX arm).
    private let proseCompiler: any ProseCadenceCompiler = CompositeProseCadenceCompiler(
        rule: RuleBasedProseCadenceCompiler(),
        mlx: NullProseCadenceCompiler()
    )

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

    // MARK: - Composed-cadence derivation (live)

    /// The cron string the composed schedule resolves to, or nil if not
    /// yet resolvable. Counter mode has no cron (fires from events).
    private var effectiveCron: String? {
        switch composeMode {
        case .cron:
            let c = cronForPreset(newSchedulePreset)
            return c.isEmpty ? nil : c
        case .prose:
            return compiledProseCron
        case .counter:
            return nil
        }
    }

    /// The parsed counter cadence (counter mode only), or nil if the
    /// expression doesn't parse.
    private var effectiveCounter: CounterCadence? {
        guard composeMode == .counter else { return nil }
        return CounterCadence.parse(newCounter)
    }

    /// Live AmplificationGuard verdict for the composed cadence, or nil
    /// when nothing resolvable has been composed yet.
    private var amplificationVerdict: AmplificationGuard.Verdict? {
        switch composeMode {
        case .counter:
            guard let counter = effectiveCounter else { return nil }
            return AmplificationGuard.validate(cron: nil, counter: counter)
        case .cron, .prose:
            guard let cron = effectiveCron else { return nil }
            return AmplificationGuard.validate(cron: cron, counter: nil)
        }
    }

    /// Next fire times for the composed cron (cron + prose modes).
    /// Empty in counter mode (no launchd fires) or before a cron resolves.
    private var nextFires: [Date] {
        guard let cron = effectiveCron else { return [] }
        return CronPreview.nextFires(cron: cron, after: Date(), count: 5)
    }

    /// Inline validation tooltip for the active compose field (a-2): the
    /// live AmplificationGuard rationale and any compile/parse error,
    /// surfaced as a hover `.help()` on the cadence field so the operator
    /// sees WHY Create is blocked without leaving the field. nil when the
    /// cadence is valid and above the amplification floor.
    private var cadenceValidationTooltip: String? {
        var lines: [String] = []
        // Compile / parse error for the active mode.
        switch composeMode {
        case .prose:
            if let err = proseError { lines.append(err) }
        case .counter:
            if effectiveCounter == nil,
               !newCounter.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("Expected `every <N> <event>` (e.g. \"every 10 tool_calls\").")
            }
        case .cron:
            if let cron = effectiveCron, CronToLaunchd.convert(cron) == nil {
                lines.append("Invalid cron expression: \"\(cron)\".")
            }
        }
        // AmplificationGuard rationale.
        if case .amplification(let reason, _)? = amplificationVerdict {
            lines.append("Amplification risk: \(reason)" + (overrideAmplification ? " (overridden)" : ""))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Whether the Create button may submit. Requires name + command,
    /// a resolvable cadence for the active mode, and an `.ok`
    /// AmplificationGuard verdict (unless the operator overrode it).
    private var canCreate: Bool {
        guard !newName.trimmingCharacters(in: .whitespaces).isEmpty,
              !newCommand.trimmingCharacters(in: .whitespaces).isEmpty else {
            return false
        }
        switch composeMode {
        case .counter: guard effectiveCounter != nil else { return false }
        case .prose:   guard compiledProseCron != nil else { return false }
        case .cron:    guard effectiveCron != nil else { return false }
        }
        switch amplificationVerdict {
        case .some(.amplification):
            if !overrideAmplification { return false }
        case .some(.ok), .none:
            break
        }
        return true
    }

    /// Recompile `prose` → cron off the main actor, then publish the
    /// result (or an inline error) back to the form. Cancels any prior
    /// in-flight compile so fast typing doesn't race.
    private func recompileProse(_ prose: String) {
        proseCompileTask?.cancel()
        let trimmed = prose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            compiledProseCron = nil
            proseError = nil
            return
        }
        proseCompileTask = Task {
            do {
                let result = try await proseCompiler.compile(prose: trimmed, locale: "en-US")
                if Task.isCancelled { return }
                compiledProseCron = result.cron
                proseError = nil
            } catch let e as ProseCadenceCompilerError {
                if Task.isCancelled { return }
                compiledProseCron = nil
                proseError = e.userMessage
            } catch {
                if Task.isCancelled { return }
                compiledProseCron = nil
                proseError = error.localizedDescription
            }
        }
    }

    /// Reset every create-form field back to defaults.
    private func resetForm() {
        newName = ""
        newSchedulePreset = "Daily"
        newCustomCron = ""
        newCommand = ""
        newBudgetLimit = ""
        createError = nil
        composeMode = .cron
        newProse = ""
        newCounter = ""
        compiledProseCron = nil
        proseError = nil
        overrideAmplification = false
        proseCompileTask?.cancel()
        editingName = nil
    }

    // MARK: - Edit-in-place (a-2)

    /// Whether the compose surface is editing an existing schedule rather
    /// than creating a new one. Drives the submit-button label/icon and the
    /// save vs. create persistence branch.
    private var isEditing: Bool { editingName != nil }

    /// Open the compose surface PREFILLED with `task`'s current cadence so
    /// the operator can edit it in place. The compose-mode is inferred from
    /// which cadence field the task was registered with (prose / counter /
    /// cron); the same field that surfaces in `taskRow`. Saving re-runs the
    /// identical compile + AmplificationGuard + gating path as create.
    private func beginEdit(_ task: ScheduledTask) {
        resetForm()
        editingName = task.name
        newName = task.name
        newCommand = task.command
        newBudgetLimit = task.budgetLimitCents.map(String.init) ?? ""

        if let prose = task.proseCadence, !prose.isEmpty {
            composeMode = .prose
            newProse = prose
            // Seed the compiled cron from the stored compiledCadence so the
            // Create gate is satisfied immediately; the live recompile on
            // edit refreshes it if the operator changes the phrase.
            compiledProseCron = task.compiledCadence ?? task.cronPattern
            recompileProse(prose)
        } else if let counter = task.eventCounterCadence, !counter.isEmpty {
            composeMode = .counter
            newCounter = counter
        } else {
            composeMode = .cron
            // Map the stored cron back onto a preset when it matches one of
            // the built-ins, else fall through to the Custom field.
            let cron = task.cronPattern
            if let preset = schedulePresets.first(where: { $0 != "Custom" && cronForPreset($0) == cron }) {
                newSchedulePreset = preset
            } else {
                newSchedulePreset = "Custom"
                newCustomCron = cron
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            showNewScheduleForm = true
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
                        resetForm()
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
            .onMove { indices, newOffset in
                moveTasks(from: indices, to: newOffset)
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

            // Edit button — opens the compose surface prefilled (a-2).
            Button {
                beginEdit(task)
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Edit this schedule's cadence")

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
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginEdit(task) }
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
            Text(isEditing ? "Edit Schedule" : "Create New Schedule")
                .font(.system(size: 14, weight: .semibold))

            // Compose-mode toggle — prose / counter / cron, mirroring the
            // `senkani schedule create` --prose / --counter-cadence / --cron flags.
            Picker("Compose mode", selection: $composeMode) {
                ForEach(ComposeMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("e.g. daily-review", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        // The name is the schedule's file id — locked while
                        // editing so a re-save overwrites the same JSON in
                        // place rather than orphaning the old file (a-2).
                        .disabled(isEditing)
                        .help(isEditing ? "Schedule name is the file id and can't be renamed in place." : "")
                }
                .frame(maxWidth: 200)

                cadenceFields
                    // Inline validation tooltip (a-2): surfaces the compile
                    // error and AmplificationGuard rationale on hover so the
                    // operator sees why Create is gated without leaving the
                    // field.
                    .help(cadenceValidationTooltip ?? "")
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

            // Live AmplificationGuard verdict — red on .amplification
            // (with an explicit override), green on .ok. Shown for all
            // three compose modes as the operator composes.
            amplificationBanner

            // Next-fires preview from CronPreview.nextFires (cron + prose).
            nextFiresPreview

            HStack(spacing: 8) {
                Button {
                    createSchedule()
                } label: {
                    Label(isEditing ? "Save Changes" : "Create",
                          systemImage: isEditing ? "square.and.arrow.down" : "checkmark.circle")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!canCreate)
                .help(canCreate ? "" : (cadenceValidationTooltip ?? "Fill in a name, command, and a valid cadence."))

                if let error = createError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }

                Spacer()
            }
        }
        .padding(16)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .onChange(of: newProse) { _, newValue in recompileProse(newValue) }
        .onChange(of: composeMode) { _, _ in createError = nil }
    }

    // MARK: - Compose-mode cadence fields

    @ViewBuilder
    private var cadenceFields: some View {
        switch composeMode {
        case .prose:
            VStack(alignment: .leading, spacing: 4) {
                Text("Prose cadence")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("e.g. every weekday at 9am", text: $newProse)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if let cron = compiledProseCron {
                    Text("Compiles to \(CronToLaunchd.humanReadable(cron))  ·  \(cron)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if let err = proseError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: 340)
        case .counter:
            VStack(alignment: .leading, spacing: 4) {
                Text("Counter cadence")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("every N event_name (e.g. every 10 tool_calls)", text: $newCounter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                if let counter = effectiveCounter {
                    Text("Fires every \(counter.everyN) \(counter.eventName) event\(counter.everyN == 1 ? "" : "s") — dispatched by HookRouter, no launchd plist.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else if !newCounter.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Expected `every <N> <event>` (e.g. \"every 10 tool_calls\").")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: 340)
        case .cron:
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
    }

    // MARK: - Amplification verdict banner

    @ViewBuilder
    private var amplificationBanner: some View {
        if let verdict = amplificationVerdict {
            switch verdict {
            case .ok:
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Schedule looks good — fires above the amplification floor.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            case .amplification(let reason, _):
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Amplification risk: \(reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                    Toggle("Override and create anyway", isOn: $overrideAmplification)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                // Inline validation tooltip (a-2): the full AmplificationGuard
                // rationale on hover, mirroring the cadence-field tooltip.
                .help("Amplification risk: \(reason)")
            }
        }
    }

    // MARK: - Next-fires preview

    @ViewBuilder
    private var nextFiresPreview: some View {
        if composeMode == .counter {
            // Counter cadences fire on events, not a clock — no cron preview.
            EmptyView()
        } else {
            let fires = nextFires
            if !fires.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Next fires")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(Array(fires.enumerated()), id: \.offset) { _, date in
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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

    /// Drag-reorder the schedule list and PERSIST the new order via
    /// ScheduleStore (a-2). `ScheduleStore.list()` orders rows by
    /// `createdAt`, so to make a reorder durable we re-stamp each row's
    /// `createdAt` to a strictly increasing sequence matching the new
    /// visual order and re-save it — keeping the existing store + existing
    /// sort, without touching Core. Names (the file id) are unchanged, so
    /// each save overwrites the same JSON file in place.
    private func moveTasks(from source: IndexSet, to destination: Int) {
        var reordered = tasks
        reordered.move(fromOffsets: source, toOffset: destination)

        // Re-stamp createdAt onto a monotonically increasing sequence so the
        // createdAt-sort in ScheduleStore.list() reproduces the new order.
        let base = Date(timeIntervalSince1970: 0)
        for (index, task) in reordered.enumerated() {
            var updated = task
            updated.createdAt = base.addingTimeInterval(Double(index))
            try? ScheduleStore.save(updated)
        }
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

        guard !name.isEmpty else {
            createError = "Name is required"
            return
        }
        guard !command.isEmpty else {
            createError = "Command is required"
            return
        }

        let budget: Int? = newBudgetLimit.isEmpty ? nil : Int(newBudgetLimit)

        // When editing in place, the row already exists under this name —
        // load it so we can preserve fields the cadence edit must NOT reset
        // (enabled state, createdAt → list position, and run history). The
        // name is locked while editing, so `name` equals the existing id and
        // a re-save overwrites the same JSON file (a-2).
        let original: ScheduledTask? = isEditing ? ScheduleStore.load(name) : nil

        // Build the per-mode task and run the same AmplificationGuard
        // gate the CLI's `senkani schedule create` applies — refusing a
        // schedule at or below the amplification floor unless the
        // operator explicitly overrode it.
        var task: ScheduledTask
        switch composeMode {
        case .cron:
            let cron = cronForPreset(newSchedulePreset)
            guard !cron.isEmpty else { createError = "Schedule is required"; return }
            guard CronToLaunchd.convert(cron) != nil else {
                createError = "Invalid cron expression: \"\(cron)\""
                return
            }
            if case .amplification(let reason, _) = AmplificationGuard.validate(cron: cron, counter: nil),
               !overrideAmplification {
                createError = "Refused (amplification): \(reason)"
                return
            }
            task = ScheduledTask(
                name: name, cronPattern: cron, command: command,
                budgetLimitCents: budget, enabled: true
            )
        case .prose:
            guard let cron = compiledProseCron else {
                createError = proseError ?? "Prose cadence has not compiled to a cron yet."
                return
            }
            guard CronToLaunchd.convert(cron) != nil else {
                createError = "Compiled cron \"\(cron)\" is invalid."
                return
            }
            if case .amplification(let reason, _) = AmplificationGuard.validate(cron: cron, counter: nil),
               !overrideAmplification {
                createError = "Refused (amplification): \(reason)"
                return
            }
            task = ScheduledTask(
                name: name, cronPattern: cron, command: command,
                budgetLimitCents: budget, enabled: true,
                proseCadence: newProse.trimmingCharacters(in: .whitespacesAndNewlines),
                compiledCadence: cron, locale: "en-US"
            )
        case .counter:
            guard let counter = effectiveCounter else {
                createError = "Counter cadence must be `every <N> <event>` (e.g. every 10 tool_calls)."
                return
            }
            if case .amplification(let reason, _) = AmplificationGuard.validate(cron: nil, counter: counter),
               !overrideAmplification {
                createError = "Refused (amplification): \(reason)"
                return
            }
            // Counter cadences fire from HookRouter, not launchd — store
            // the COUNTER: sentinel cron + the original expression.
            task = ScheduledTask(
                name: name, cronPattern: counter.sentinelCronPattern, command: command,
                budgetLimitCents: budget, enabled: true,
                eventCounterCadence: newCounter.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Preserve the existing row's lifecycle fields when editing so a
        // cadence edit doesn't silently re-enable a disabled schedule,
        // bump it to the bottom of the list, or wipe its run history.
        if let original {
            task.enabled = original.enabled
            task.createdAt = original.createdAt
            task.lastRunAt = original.lastRunAt
            task.lastRunResult = original.lastRunResult
        }

        do {
            switch composeMode {
            case .cron, .prose:
                // Match the CLI's `runCron` / `runProse` (ScheduleCommand):
                // write the JSON config AND render + write the launchd plist
                // to ~/Library/LaunchAgents/, then load it with launchctl.
                // `ScheduleStore.save` alone (the old path) only wrote the
                // JSON, so a GUI-created cron/prose schedule was recorded but
                // never fired.
                _ = try PresetInstaller.install(task: task)
            case .counter:
                // Counter cadences fire from HookRouter post-tool reactions,
                // not launchd — persist the COUNTER: sentinel cron with NO
                // plist (matches `ScheduleCommand.runCounterCadence`).
                try ScheduleStore.save(task)
            }
            withAnimation(.easeInOut(duration: 0.2)) {
                showNewScheduleForm = false
                createError = nil
            }
            loadTasks()
        } catch let error as PresetInstaller.InstallError {
            // Surface install failures inline instead of silently dropping
            // the schedule.
            switch error {
            case .invalidCronPattern(let pattern):
                createError = "Invalid cron expression: \"\(pattern)\""
            case .writeFailed(let detail):
                createError = "Install failed: \(detail)"
            }
        } catch {
            createError = error.localizedDescription
        }
    }
}
