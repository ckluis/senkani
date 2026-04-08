import Foundation
import Core

/// Watches the pane-commands.jsonl file for new IPC commands from MCP tools.
/// Same GCD DispatchSource pattern as MetricsWatcher.
/// When a command arrives, calls the handler on the main thread and writes
/// a response file for the MCP tool to pick up.
final class PaneCommandWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Called on the main queue with the decoded command.
    /// Must return a PaneIPCResponse synchronously.
    var onCommand: ((PaneIPCCommand) -> PaneIPCResponse)?

    func start() {
        PaneIPCPaths.ensureDirectories()

        let path = PaneIPCPaths.commandFile
        // Create the file if it doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        fileHandle = handle
        // Start at end — only process new commands
        lastOffset = handle.seekToEndOfFile()

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.readNewCommands()
        }

        source.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
        }

        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func readNewCommands() {
        guard let handle = fileHandle else { return }

        handle.seek(toFileOffset: lastOffset)
        let data = handle.readDataToEndOfFile()
        lastOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let command = try? decoder.decode(PaneIPCCommand.self, from: lineData) else {
                continue
            }

            // Dispatch to main thread for WorkspaceModel operations
            DispatchQueue.main.async { [weak self] in
                guard let handler = self?.onCommand else { return }
                let response = handler(command)
                self?.writeResponse(response)
            }
        }
    }

    private func writeResponse(_ response: PaneIPCResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(response) else { return }

        let path = PaneIPCPaths.responsePath(for: response.id)
        try? data.write(to: URL(fileURLWithPath: path))
    }

    deinit {
        stop()
    }
}
