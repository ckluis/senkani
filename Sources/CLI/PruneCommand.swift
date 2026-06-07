import ArgumentParser
import Core
import Foundation

/// `senkani prune --dataset <id>` — operator-visible primitive for
/// trimming a `runtime_telemetry_dataset` to a target byte budget.
/// Shipped under V.18a-2 (2026-05-22) per the V.18 RuntimeTelemetryDataset
/// decomposition. The automatic per-table 500 MB cap is enforced inside
/// `RuntimeTelemetryStore.insertSpan`/`insertLog`; this CLI is the
/// explicit knob for the operator who wants to free space immediately
/// or shrink a dataset below the live cap.
///
/// Idempotent: running twice with the same `--target-bytes` value
/// against the same dataset leaves the byte counter unchanged after the
/// first invocation. The acceptance check in
/// `RuntimeTelemetryPruneTests.cliPruneIsIdempotent` pins this.
struct Prune: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Trim a runtime_telemetry_dataset to a target byte budget. Idempotent."
    )

    @Option(name: .long, help: "Dataset id (from runtime_telemetry_dataset.id).")
    var dataset: Int64

    @Option(
        name: [.customLong("target-bytes")],
        help: "Target byte budget for the dataset. Defaults to the per-table cap (500 MB) so this is a no-op when the dataset is below the live cap."
    )
    var targetBytes: Int = RuntimeTelemetryStore.defaultTableCapBytes

    @Flag(name: .long, help: "Emit a one-line JSON record instead of human-readable text.")
    var json: Bool = false

    mutating func run() throws {
        guard dataset > 0 else {
            FileHandle.standardError.write(Data("error: --dataset must be a positive integer\n".utf8))
            throw ExitCode.failure
        }
        guard targetBytes >= 0 else {
            FileHandle.standardError.write(Data("error: --target-bytes must be >= 0\n".utf8))
            throw ExitCode.failure
        }

        let db = SessionDatabase.shared
        let store = db.runtimeTelemetryStore!
        let bytesBefore = store.bytesUsed(datasetId: dataset)
        if bytesBefore == 0 {
            // No row OR genuinely empty dataset. Distinguish for the operator.
            // Both cases are no-ops for the prune itself; the dataset-missing
            // case is a hint at a typo.
            if json {
                let payload: [String: Any] = [
                    "dataset": dataset,
                    "target_bytes": targetBytes,
                    "bytes_before": 0,
                    "bytes_after": 0,
                    "spans_deleted": 0,
                    "logs_deleted": 0,
                    "noop": true,
                ]
                emitJSON(payload)
            } else {
                print("dataset \(dataset): 0 bytes used; nothing to prune")
            }
            return
        }

        let (spansDeleted, logsDeleted) = store.pruneDatasetToTarget(
            datasetId: dataset,
            targetBytes: targetBytes
        )
        let bytesAfter = store.bytesUsed(datasetId: dataset)

        if json {
            let payload: [String: Any] = [
                "dataset": dataset,
                "target_bytes": targetBytes,
                "bytes_before": bytesBefore,
                "bytes_after": bytesAfter,
                "spans_deleted": spansDeleted,
                "logs_deleted": logsDeleted,
                "noop": (spansDeleted == 0 && logsDeleted == 0),
            ]
            emitJSON(payload)
        } else {
            let humanBefore = Self.formatBytes(bytesBefore)
            let humanAfter = Self.formatBytes(bytesAfter)
            let humanTarget = Self.formatBytes(targetBytes)
            if spansDeleted == 0 && logsDeleted == 0 {
                print("dataset \(dataset): \(humanBefore) used (≤ target \(humanTarget)); no-op")
            } else {
                print("dataset \(dataset): \(humanBefore) → \(humanAfter) (target \(humanTarget)); deleted \(spansDeleted) spans + \(logsDeleted) logs")
            }
        }
    }

    private func emitJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
    }

    static func formatBytes(_ bytes: Int) -> String {
        let mb = 1024 * 1024
        let kb = 1024
        if bytes >= mb {
            let value = Double(bytes) / Double(mb)
            return String(format: "%.1f MB", value)
        } else if bytes >= kb {
            let value = Double(bytes) / Double(kb)
            return String(format: "%.1f KB", value)
        }
        return "\(bytes) B"
    }
}
