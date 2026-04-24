import Testing
@testable import Core
import Foundation

@Suite("PresetCatalog — shipped defaults + user presets")
struct PresetCatalogTests {

    @Test("Shipped catalog has exactly the five day-1 presets")
    func shippedCatalogHasFivePresets() {
        let names = PresetCatalog.shipped.map { $0.name }.sorted()
        #expect(names == [
            "autoresearch",
            "competitive-scan",
            "log-rotation",
            "morning-brief",
            "senkani-improve"
        ])
    }

    @Test("Each shipped preset parses with a valid cron pattern")
    func shippedPresetsParseWithValidCron() {
        for preset in PresetCatalog.shipped {
            #expect(CronToLaunchd.convert(preset.cronPattern) != nil,
                    "Preset \(preset.name) has invalid cron: \(preset.cronPattern)")
        }
    }

    @Test("Each shipped preset's JSON round-trips through decode/encode")
    func shippedPresetsRoundTrip() throws {
        for preset in PresetCatalog.shipped {
            let data = try PresetCatalog.encode(preset)
            let decoded = try PresetCatalog.decode(data)
            #expect(decoded == preset, "Round-trip mismatch for \(preset.name)")
        }
    }

    @Test("User presets under the override dir shadow shipped defaults")
    func userPresetsShadowShipped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-preset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // User "log-rotation" with a different cron.
        let userPreset = ScheduledPreset(
            name: "log-rotation",
            version: 1,
            cronPattern: "15 4 * * *",
            command: "echo user-override",
            engine: .shell,
            description: "User-override log rotation",
            docUrl: "/local"
        )
        let data = try PresetCatalog.encode(userPreset)
        try data.write(to: tmp.appendingPathComponent("log-rotation.json"))

        PresetCatalog.withUserDir(tmp.path) {
            let all = PresetCatalog.all()
            let found = all.first { $0.name == "log-rotation" }
            #expect(found?.command == "echo user-override")
            #expect(found?.description == "User-override log rotation")
        }
    }

    @Test("User-only preset appears alongside shipped presets")
    func userOnlyPresetListed() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("senkani-preset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let userPreset = ScheduledPreset(
            name: "custom-sweep",
            version: 1,
            cronPattern: "0 5 * * *",
            command: "custom-sweep.sh",
            engine: .shell,
            description: "Custom preset",
            docUrl: "/local"
        )
        let data = try PresetCatalog.encode(userPreset)
        try data.write(to: tmp.appendingPathComponent("custom-sweep.json"))

        PresetCatalog.withUserDir(tmp.path) {
            let names = PresetCatalog.all().map { $0.name }
            #expect(names.contains("custom-sweep"))
            #expect(PresetCatalog.isShipped("custom-sweep") == false)
            #expect(PresetCatalog.isShipped("log-rotation") == true)
        }
    }

    @Test("Placeholder extraction finds topic/competitor but not redirections")
    func placeholderExtractionIsTokenOnly() {
        let autoresearch = PresetCatalog.find("autoresearch")
        #expect(autoresearch?.placeholders == ["topic"])

        let competitive = PresetCatalog.find("competitive-scan")
        #expect(competitive?.placeholders == ["competitor"])

        // A handcrafted preset with a shell redirection-looking substring
        // must NOT produce a phantom placeholder.
        let fake = ScheduledPreset(
            name: "tricky",
            cronPattern: "0 0 * * *",
            command: "cat <&1 > out.txt",
            engine: .shell,
            description: "",
            docUrl: "/"
        )
        #expect(fake.placeholders == [])
    }
}
