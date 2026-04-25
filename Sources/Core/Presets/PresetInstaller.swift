import Foundation

/// Shared installer for `ScheduledTask`s. Writes the task JSON via
/// `ScheduleStore.save`, generates the launchd plist, and (in
/// production mode) runs `launchctl load`. Used by both
/// `senkani schedule create` (the low-level surface) and
/// `senkani schedule preset install` so the two code paths can't
/// drift.
///
/// The plist generation used to live as a private method on
/// `Schedule.Create`; extracting it here lets the preset install path
/// produce byte-identical plists without duplicating 80 LOC.
public enum PresetInstaller {

    /// Result of building + writing the plist, independent of the
    /// launchctl-load step. Tests can invoke `install` with
    /// `loadWithLaunchctl: false` and assert the XML on disk.
    public struct InstallResult: Sendable {
        public let task: ScheduledTask
        public let plistPath: String
        public let plistXML: String
        public let launchctlLoaded: Bool
    }

    public enum InstallError: Error, Equatable {
        case invalidCronPattern(String)
        case writeFailed(String)
    }

    /// Write the `ScheduledTask` JSON + generate the launchd plist +
    /// (if `loadWithLaunchctl`) run `launchctl load`. Callers:
    /// - `schedule create` → `loadWithLaunchctl: true`
    /// - `schedule preset install` → `loadWithLaunchctl: true`
    /// - tests → `loadWithLaunchctl: false`
    ///
    /// `binaryPath` defaults to the running executable's path; tests
    /// pass a stable placeholder so the generated XML is deterministic.
    public static func install(
        task: ScheduledTask,
        binaryPath: String? = nil,
        loadWithLaunchctl: Bool = true
    ) throws -> InstallResult {
        let resolvedBinary = binaryPath
            ?? ProcessInfo.processInfo.arguments.first
            ?? "/usr/local/bin/senkani"

        // Validate the cron up front so we fail before touching disk.
        guard let intervals = CronToLaunchd.convert(task.cronPattern) else {
            throw InstallError.invalidCronPattern(task.cronPattern)
        }

        // 1. Save the task JSON
        do {
            try ScheduleStore.save(task)
        } catch {
            throw InstallError.writeFailed("ScheduleStore.save failed: \(error)")
        }

        // 2. Ensure logs dir exists
        let fm = FileManager.default
        let logsDir = ScheduleStore.logsDir
        if !fm.fileExists(atPath: logsDir) {
            try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        }

        // 3. Build plist XML
        let xml = renderPlistXML(task: task, binaryPath: resolvedBinary, intervals: intervals)

        // 4. Write plist
        let label = ScheduleStore.plistLabel(for: task.name)
        let launchAgentsDir = ScheduleStore.launchAgentsDir
        let plistPath = launchAgentsDir + "/\(label).plist"
        if !fm.fileExists(atPath: launchAgentsDir) {
            try? fm.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)
        }
        do {
            try xml.write(toFile: plistPath, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeFailed("plist write failed: \(error)")
        }

        // 5. Optionally run launchctl load
        var loaded = false
        if loadWithLaunchctl {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["load", plistPath]
            do {
                try process.run()
                process.waitUntilExit()
                loaded = process.terminationStatus == 0
                if !loaded {
                    FileHandle.standardError.write(
                        Data("Warning: launchctl load exited with status \(process.terminationStatus)\n".utf8)
                    )
                }
            } catch {
                FileHandle.standardError.write(
                    Data("Warning: launchctl load threw: \(error)\n".utf8)
                )
            }
        }

        return InstallResult(
            task: task,
            plistPath: plistPath,
            plistXML: xml,
            launchctlLoaded: loaded
        )
    }

    /// Pure plist XML builder — no side effects. Exposed so tests can
    /// assert the XML shape for a given (task, binaryPath) pair without
    /// writing to disk.
    public static func renderPlistXML(
        task: ScheduledTask,
        binaryPath: String,
        intervals: [[String: Int]]
    ) -> String {
        let label = ScheduleStore.plistLabel(for: task.name)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(binaryPath)</string>
                <string>schedule</string>
                <string>run</string>
                <string>--name</string>
                <string>\(task.name)</string>
            </array>
            <key>StartCalendarInterval</key>

        """

        if intervals.count == 1 {
            xml += "    <dict>\n"
            for (key, value) in intervals[0].sorted(by: { $0.key < $1.key }) {
                xml += "        <key>\(key)</key>\n"
                xml += "        <integer>\(value)</integer>\n"
            }
            xml += "    </dict>\n"
        } else {
            xml += "    <array>\n"
            for interval in intervals {
                xml += "        <dict>\n"
                for (key, value) in interval.sorted(by: { $0.key < $1.key }) {
                    xml += "            <key>\(key)</key>\n"
                    xml += "            <integer>\(value)</integer>\n"
                }
                xml += "        </dict>\n"
            }
            xml += "    </array>\n"
        }

        xml += """
            <key>StandardOutPath</key>
            <string>\(home)/.senkani/logs/\(task.name).log</string>
            <key>StandardErrorPath</key>
            <string>\(home)/.senkani/logs/\(task.name).err</string>
        </dict>
        </plist>

        """
        return xml
    }
}
