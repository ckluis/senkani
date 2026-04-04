import SwiftUI

/// Tail a log file in real-time with filtering and auto-scroll.
/// Uses DispatchSource FSEvents to watch for file changes.
struct LogViewerPane: View {
    @Bindable var pane: PaneModel
    @State private var logPath: String = ""
    @State private var lines: [LogLine] = []
    @State private var filterText: String = ""
    @State private var autoScroll = true
    @State private var watcher: DispatchSourceFileSystemObject?
    @State private var fileHandle: FileHandle?
    @State private var isWatching = false

    private var filteredLines: [LogLine] {
        if filterText.isEmpty { return lines }
        return lines.filter { $0.text.localizedCaseInsensitiveContains(filterText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Controls bar
            HStack(spacing: 6) {
                TextField("Log file path...", text: $logPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SenkaniTheme.paneBody)
                    .cornerRadius(3)
                    .onSubmit { startWatching() }

                Button(isWatching ? "Stop" : "Tail") {
                    if isWatching { stopWatching() } else { startWatching() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Divider().frame(height: 14)

                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10))
                    .foregroundStyle(SenkaniTheme.textTertiary)

                TextField("Filter...", text: $filterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10))
                    .frame(width: 100)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SenkaniTheme.paneBody)
                    .cornerRadius(3)

                Toggle(isOn: $autoScroll) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 10))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Auto-scroll to bottom")

                Text("\(lines.count) lines")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(SenkaniTheme.textTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SenkaniTheme.paneShell)

            Rectangle().fill(SenkaniTheme.appBackground).frame(height: 0.5)

            // Log content
            if lines.isEmpty && !isWatching {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredLines) { line in
                                HStack(spacing: 0) {
                                    Text("\(line.lineNumber)")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(SenkaniTheme.textTertiary.opacity(0.4))
                                        .frame(width: 36, alignment: .trailing)
                                        .padding(.trailing, 6)

                                    Text(line.text)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(lineColor(line.text))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 1)
                                .padding(.horizontal, 4)
                                .id(line.id)
                            }
                        }
                    }
                    .background(SenkaniTheme.paneBody)
                    .onChange(of: lines.count) { _, _ in
                        if autoScroll, let last = filteredLines.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .onDisappear { stopWatching() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.line.last.and.arrowtriangle.forward")
                .font(.system(size: 32))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Text("Enter a log file path and click Tail")
                .font(.system(size: 12))
                .foregroundStyle(SenkaniTheme.textSecondary)
            Text("e.g. /var/log/system.log or ~/.senkani/logs/schedule.log")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(SenkaniTheme.textTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SenkaniTheme.paneBody)
    }

    /// Color-code lines by common log patterns
    private func lineColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("panic") {
            return .red
        } else if lower.contains("warn") {
            return .yellow
        } else if lower.contains("info") {
            return SenkaniTheme.accentAnalytics
        } else if lower.contains("debug") || lower.contains("trace") {
            return SenkaniTheme.textTertiary
        }
        return SenkaniTheme.textPrimary
    }

    private func startWatching() {
        stopWatching()
        let path = logPath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return }

        // Read existing content
        if let data = FileManager.default.contents(atPath: path),
           let content = String(data: data, encoding: .utf8) {
            let existingLines = content.components(separatedBy: "\n")
            lines = existingLines.enumerated().map { idx, text in
                LogLine(lineNumber: idx + 1, text: text)
            }
        }

        // Open file handle for tailing
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        fh.seekToEndOfFile()
        fileHandle = fh

        // Watch for changes via FSEvents
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )

        source.setEventHandler { [self] in
            let newData = fh.readDataToEndOfFile()
            guard !newData.isEmpty, let text = String(data: newData, encoding: .utf8) else { return }
            let newLines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            let startNum = lines.count + 1
            let additions = newLines.enumerated().map { idx, text in
                LogLine(lineNumber: startNum + idx, text: text)
            }
            lines.append(contentsOf: additions)
        }

        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        isWatching = true
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        fileHandle?.closeFile()
        fileHandle = nil
        isWatching = false
    }
}

struct LogLine: Identifiable {
    let id = UUID()
    let lineNumber: Int
    let text: String
}
