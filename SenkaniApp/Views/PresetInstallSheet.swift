import SwiftUI
import Core

/// Sheet surface for installing one of the shipped `ScheduledPreset`s.
///
/// Renders the list from `PresetCatalog.all()` with each preset's
/// description + engine class + prerequisite readiness. An "Install"
/// button on each row shells out to `senkani schedule preset install`
/// so the UI and CLI code paths stay single-sourced.
///
/// Launched from the Schedules pane header (`ScheduleView`'s "Install
/// preset" button).
struct PresetInstallSheet: View {
    @Binding var isPresented: Bool
    var onInstalled: () -> Void

    @State private var presets: [ScheduledPreset] = []
    @State private var selected: ScheduledPreset?
    @State private var installError: String?
    @State private var installingName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if presets.isEmpty {
                emptyView
            } else {
                listView
            }
        }
        .frame(minWidth: 560, idealWidth: 640, minHeight: 420, idealHeight: 480)
        .background(Color(.windowBackgroundColor))
        .onAppear {
            presets = PresetCatalog.all()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Install a scheduled preset")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(presets.count) preset\(presets.count == 1 ? "" : "s") available")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Done") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Text("No presets found.")
                .font(.system(size: 13))
            Text("Drop a JSON file into ~/.senkani/presets/ to add your own.")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(presets, id: \.name) { preset in
                    presetRow(preset)
                }
            }
            .padding(12)
        }
    }

    private func presetRow(_ preset: ScheduledPreset) -> some View {
        let ready = PresetPrerequisiteCheck.check(preset)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                Text(preset.engine.rawValue)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                Spacer()
                if ready.fullyReady {
                    Text("ready").font(.system(size: 10)).foregroundStyle(.green)
                } else {
                    Text("\(ready.warnings.count) prereq warning\(ready.warnings.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
                Button(installingName == preset.name ? "Installing…" : "Install") {
                    install(preset)
                }
                .disabled(installingName != nil)
                .controlSize(.small)
            }
            Text(preset.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func install(_ preset: ScheduledPreset) {
        installingName = preset.name
        installError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "senkani schedule preset install \(preset.name)"]
            let errPipe = Pipe()
            process.standardError = errPipe
            do {
                try process.run()
                process.waitUntilExit()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: errData, encoding: .utf8) ?? ""
                DispatchQueue.main.async {
                    installingName = nil
                    if process.terminationStatus != 0 {
                        installError = msg.isEmpty ? "Install failed (exit \(process.terminationStatus))." : msg
                    } else {
                        onInstalled()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    installingName = nil
                    installError = "Failed to spawn installer: \(error.localizedDescription)"
                }
            }
        }
    }
}
