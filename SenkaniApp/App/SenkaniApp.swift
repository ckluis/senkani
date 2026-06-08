import SwiftUI
import Core
import MCPServer

struct SenkaniGUI: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var menuBarManager = MenuBarManager()

    init() {
        do {
            try AutoRegistration.cleanupGlobalSettings()
        } catch {
            // Non-fatal -- log and continue. The app works without cleanup.
            FileHandle.standardError.write(Data("[senkani] Cleanup failed: \(error.localizedDescription)\n".utf8))
        }
        AutoRegistration.installHookWrapper()
        Self.cleanupStaleMCPProcesses()
        Self.cleanupStaleMCPFiles()
        Self.cleanupRetiredFCSITFirstUseKey()

        // Start hook socket listener so senkani-hook binary can connect
        SocketServerManager.shared.hookHandler = { HookRouter.handle(eventJSON: $0) }
        SocketServerManager.shared.start()

        // Wire entity tracking: native Claude Code tool args → KB mention counts
        HookRouter.entityObserver = { KBObserver.observeHookEvent(toolName: $0, toolInput: $1) }

        // V.11b — load installed pack policy fragments. Subsequent
        // CLI installs/uninstalls converge through the on-event
        // mtime check inside HookRouter.handle().
        HookRouter.refreshInstalledPacks()

        // t4c-1 — install the production credential-vault bridge so the
        // T.4b CredentialGateway (which runs inside the just-wired
        // SocketServerManager hookHandler → HookRouter.handle) resolves
        // real vault reads from `CredentialVault.shared` via a balanced
        // DispatchSemaphore actor hop, instead of the default deny-
        // everything fallback. Fail-CLOSED preserved: `.shared` is an
        // EMPTY InMemoryKeychainStore in production today (the operator-
        // gated real-Keychain swap is the parent walk's remainder,
        // deliberately NOT flipped here), so a missing key still DENIES.
        HookRouter.installProductionCredentialVaultBridge()

        // T.6 — production notification wiring. Install the router
        // before requesting UN authorization so an immediately-
        // following `NotificationDelivery.deliver(...)` from any
        // Core producer reaches the (now non-nil) router. UN's
        // own delivery is async and gated by the user's grant; if
        // the operator hasn't yet accepted the TCC prompt the
        // OS layer silently swallows the banner — the in-process
        // router is still installed correctly.
        NotificationBootstrap.bootstrap()
        NotificationBootstrap.requestAuthorizationIfNeeded()
    }

    /// One-shot removal of the retired FCSIT first-use disclosure
    /// UserDefaults key. The first-use popover surface was retired
    /// 2026-05-11 (`fcsit-pane-toggles-ux-redesign`) along with the
    /// chevron / gear / drawer affordances — clicking any FCSIT
    /// letter now opens the settings panel directly. The defaults
    /// key is no longer read or written; removing it on launch
    /// keeps `senkani uninstall` parity and prevents leftover state
    /// on cfprefsd from confusing future audits. Idempotent —
    /// harmless if the key is already absent.
    static func cleanupRetiredFCSITFirstUseKey() {
        UserDefaults.standard.removeObject(
            forKey: FCSITDisclosure.retiredFirstUseSeenDefaultsKey)
    }

    /// Kill stale MCP server processes left over from previous sessions.
    /// Claude Code spawns MCP servers that should exit when stdin closes,
    /// but old versions (before the stdin EOF fix) may linger indefinitely.
    private static func cleanupStaleMCPProcesses() {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "mcp-server"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return // pgrep not available or failed — skip cleanup
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let myPID = ProcessInfo.processInfo.processIdentifier
        let pids = output.split(separator: "\n")
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 != myPID }

        if pids.count > 5 {
            print("🧹 [CLEANUP] Found \(pids.count) stale MCP server processes — sending SIGTERM")
            for pid in pids {
                kill(pid, SIGTERM)
            }
        }
    }

    /// One-time migration: find every .mcp.json on disk (via Spotlight) that
    /// has a senkani entry and remove it. Runs on every launch; is a no-op
    /// once all stale files are cleaned. Does not touch non-senkani entries.
    private static func cleanupStaleMCPFiles() {
        // mdfind uses the Spotlight index — fast, finds all .mcp.json files
        let pipe = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = ["-name", ".mcp.json"]
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return }
        proc.waitUntilExit()

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                            encoding: .utf8) ?? ""
        let paths = output.split(separator: "\n")
                          .map(String.init)
                          .filter { !$0.isEmpty }

        let fm = FileManager.default
        var cleaned = 0

        for path in paths {
            guard let data = fm.contents(atPath: path),
                  var cfg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var servers = cfg["mcpServers"] as? [String: Any],
                  servers["senkani"] != nil
            else { continue }

            servers.removeValue(forKey: "senkani")

            if servers.isEmpty {
                cfg.removeValue(forKey: "mcpServers")
            } else {
                cfg["mcpServers"] = servers
            }

            if cfg.isEmpty {
                try? fm.removeItem(atPath: path)
            } else if let updated = try? JSONSerialization.data(
                withJSONObject: cfg,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                try? updated.write(to: URL(fileURLWithPath: path))
            }

            cleaned += 1
        }

        if cleaned > 0 {
            print("[SENKANI] Removed stale MCP entries from \(cleaned) .mcp.json file(s)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 700)

        MenuBarExtra("Senkani", systemImage: "bolt.circle") {
            MenuBarContentView(manager: menuBarManager)
        }
    }
}
