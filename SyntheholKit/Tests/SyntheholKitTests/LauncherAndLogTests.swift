import Foundation
import Testing
@testable import SyntheholKit

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-phase5-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct LauncherExporterTests {
    @Test func exportsWellFormedLauncherApp() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp.appending(path: "Bottle"), settings: BottleSettings(name: "B"))
        let game = InstalledGame(store: "steam", storeGameID: "975370", name: "Dwarf Fortress")

        let appURL = try LauncherExporter.export(
            game: game, bottle: bottle, to: temp.appending(path: "Launchers")
        )
        #expect(appURL.lastPathComponent == "Dwarf Fortress.app")

        let plistURL = appURL.appending(path: "Contents/Info.plist")
        let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: plistURL), format: nil
        ) as? [String: Any]
        #expect(plist?["LSApplicationCategoryType"] as? String == "public.app-category.games")
        #expect(plist?["CFBundleExecutable"] as? String == "launch")
        #expect(plist?["CFBundleIdentifier"] as? String
            == "com.colinobrien.Synthehol.launcher.steam-975370")

        let script = appURL.appending(path: "Contents/MacOS/launch")
        let text = try String(contentsOf: script, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/sh"))
        #expect(text.contains("synthehol://launch?"))
        #expect(text.contains("store=steam"))
        #expect(text.contains("game=975370"))
        #expect(FileManager.default.isExecutableFile(atPath: script.path(percentEncoded: false)))
    }

    @Test func launchURLRoundtripsThroughURLComponents() {
        let bottle = Bottle(
            url: URL(filePath: "/tmp/My Bottles/ABC-123"),
            settings: BottleSettings(name: "B")
        )
        let game = InstalledGame(store: "steam", storeGameID: "620", name: "Portal 2")
        let url = LauncherExporter.launchURL(for: game, in: bottle)

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(
            uniqueKeysWithValues: (components?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } }
        )
        #expect(url.scheme == "synthehol")
        #expect(url.host() == "launch")
        #expect(params["bottle"] == "/tmp/My Bottles/ABC-123")
        #expect(params["store"] == "steam")
        #expect(params["game"] == "620")
    }

    @Test func sanitizesSlashesInGameNames()  throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))
        let game = InstalledGame(store: "steam", storeGameID: "1", name: "Half/Life: Extra")
        let appURL = try LauncherExporter.export(game: game, bottle: bottle, to: temp)
        #expect(appURL.lastPathComponent == "Half-Life - Extra.app")
    }
}

struct WineLogWriterTests {
    @Test func writesHeaderAndAppendsLines() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let writer = try #require(WineLogWriter(
            label: "steam Test", header: [("Bottle", "/tmp/b")], directory: temp
        ))
        writer.append("hello")
        writer.append("world\n")
        writer.close()

        let text = try String(contentsOf: writer.fileURL, encoding: .utf8)
        #expect(text.contains("Synthehol session log — steam Test"))
        #expect(text.contains("Bottle: /tmp/b"))
        #expect(text.hasSuffix("hello\nworld\n"))
    }

    @Test func deletesOnlyOldLogs() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let old = temp.appending(path: "old.log")
        let fresh = temp.appending(path: "fresh.log")
        try Data("old".utf8).write(to: old)
        try Data("new".utf8).write(to: fresh)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.now.addingTimeInterval(-10 * 86_400)],
            ofItemAtPath: old.path(percentEncoded: false)
        )

        WineLogWriter.deleteOldLogs(olderThanDays: 7, in: temp)
        #expect(!FileManager.default.fileExists(atPath: old.path(percentEncoded: false)))
        #expect(FileManager.default.fileExists(atPath: fresh.path(percentEncoded: false)))
    }
}
