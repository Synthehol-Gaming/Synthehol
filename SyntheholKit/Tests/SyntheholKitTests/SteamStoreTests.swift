import Foundation
import Testing
@testable import SyntheholKit

private func makeBottleWithSteam() throws -> Bottle {
    let temp = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-steam-\(UUID().uuidString)")
    let steamapps = temp.appending(path: "drive_c/Program Files (x86)/Steam/steamapps")
    try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
    try Data().write(to: steamapps.deletingLastPathComponent().appending(path: "steam.exe"))
    return Bottle(url: temp, settings: BottleSettings(name: "Steam"))
}

private func writeManifest(appID: Int, name: String, state: Int, in steamapps: URL) throws {
    let acf = """
    "AppState"
    {
    \t"appid"\t\t"\(appID)"
    \t"name"\t\t"\(name)"
    \t"StateFlags"\t\t"\(state)"
    \t"installdir"\t\t"\(name)"
    }
    """
    try Data(acf.utf8).write(to: steamapps.appending(path: "appmanifest_\(appID).acf"))
}

struct SteamStoreTests {
    @Test func discoversFullyInstalledGamesSorted() throws {
        let bottle = try makeBottleWithSteam()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let store = SteamStore()
        let steamapps = store.steamDirectory(in: bottle).appending(path: "steamapps")

        try writeManifest(appID: 620, name: "Portal 2", state: 4, in: steamapps)
        try writeManifest(appID: 400, name: "Portal", state: 4, in: steamapps)
        try writeManifest(appID: 1091500, name: "Cyberpunk 2077", state: 1028, in: steamapps) // installed + update pending

        #expect(store.isInstalled(in: bottle))
        let games = try store.installedGames(in: bottle)
        #expect(games.map(\.name) == ["Cyberpunk 2077", "Portal", "Portal 2"])
        #expect(games.map(\.id).contains("steam:620"))
        #expect(games.allSatisfy { $0.posterURL != nil })
    }

    @Test func skipsGamesStillDownloading() throws {
        let bottle = try makeBottleWithSteam()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let store = SteamStore()
        let steamapps = store.steamDirectory(in: bottle).appending(path: "steamapps")

        try writeManifest(appID: 730, name: "Counter-Strike 2", state: 2, in: steamapps) // update required, not installed
        #expect(try store.installedGames(in: bottle).isEmpty)
    }

    @Test func readsExtraLibraryFoldersFromVDF() throws {
        let bottle = try makeBottleWithSteam()
        defer { try? FileManager.default.removeItem(at: bottle.url) }
        let store = SteamStore()
        let steamapps = store.steamDirectory(in: bottle).appending(path: "steamapps")

        let extra = bottle.driveC.appending(path: "SteamLibrary/steamapps")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try writeManifest(appID: 620, name: "Portal 2", state: 4, in: extra)

        let vdf = #"""
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"C:\\Program Files (x86)\\Steam"
        	}
        	"1"
        	{
        		"path"		"C:\\SteamLibrary"
        	}
        }
        """#
        try Data(vdf.utf8).write(to: steamapps.appending(path: "libraryfolders.vdf"))

        let games = try store.installedGames(in: bottle)
        #expect(games.map(\.name) == ["Portal 2"])
    }

    @Test func mapsWindowsPathsThroughDriveC() {
        let driveC = URL(filePath: "/tmp/bottle/drive_c")
        let mapped = SteamStore.mapWindowsPath(#"C:\\SteamLibrary"#, driveC: driveC)
        #expect(mapped?.path(percentEncoded: false) == "/tmp/bottle/drive_c/SteamLibrary")
        #expect(SteamStore.mapWindowsPath(#"D:\\Games"#, driveC: driveC) == nil)
    }
}
