import Foundation

/// Watches a JSONL metrics file for new entries and updates a PaneMetrics model.
/// Uses GCD DispatchSource for FSEvents-based file monitoring.
final class MetricsWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private let path: String
    private let metrics: PaneMetrics
    private let decoder = JSONDecoder()

    init(path: String, metrics: PaneMetrics) {
        self.path = path
        self.metrics = metrics
    }

    func start() {
        // Create the file if it doesn't exist
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        fileHandle = handle
        lastOffset = handle.seekToEndOfFile()

        let fd = handle.fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.readNewEntries()
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

    private func readNewEntries() {
        guard let handle = fileHandle else { return }

        handle.seek(toFileOffset: lastOffset)
        let data = handle.readDataToEndOfFile()
        lastOffset = handle.offsetInFile

        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let metric = try? decoder.decode(MetricEntry.self, from: lineData) {
                DispatchQueue.main.async { [weak self] in
                    self?.metrics.record(
                        rawBytes: metric.rawBytes,
                        filteredBytes: metric.filteredBytes,
                        secrets: metric.secretsFound,
                        feature: nil,
                        command: metric.command
                    )
                }
            }
        }
    }

    deinit {
        stop()
    }
}

/// Matches the CommandMetric struct from SessionMetrics.swift
private struct MetricEntry: Codable {
    let command: String
    let rawBytes: Int
    let filteredBytes: Int
    let savedBytes: Int
    let savingsPercent: Double
    let secretsFound: Int
    let timestamp: Date
}
