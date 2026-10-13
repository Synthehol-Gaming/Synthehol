import Foundation
import Testing
@testable import SyntheholKit

private func nativeManifest(_ id: Int, _ name: String, state: Int = 4) -> Data {
    Data("""
    "AppState"
    {
        "appid" "\(id)"
        "name" "\(name)"
        "StateFlags" "\(state)"
        "installdir" "\(name)"
    }
    """.utf8)
}

struct NativeSteamStoreTests {
    @Test func rebuildBacksUpSystemAndPreservesGameData() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "synthehol-rebuild-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let parent = root.appending(path: "steamapps/compatdata/620")
        let prefix = parent.appending(path: "pfx")
        for relative in ["drive_c/users/crossover/AppData/Local/Game/save.dat", "drive_c/ProgramData/Game/save.dat", "drive_c/Program Files/Game/save.dat", "drive_c/windows/system32/ntdll.dll", "user.reg", ".update-timestamp"] {
            let file = prefix.appending(path: relative)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(relative.utf8).write(to: file)
        }
        try fm.createSymbolicLink(atPath: prefix.appending(path: "drive_c/users/steamuser").path, withDestinationPath: "crossover")
        try Data("old-runtime".utf8).write(to: parent.appending(path: "synthehol-build"))
        let store = NativeSteamStore(steamRoot: root)
        let game = InstalledGame(store: NativeSteamStore.storeID, storeGameID: "620", name: "Portal 2")
        let backup = try await store.rebuildPrefix(for: game)
        for relative in ["drive_c/users/crossover/AppData/Local/Game/save.dat", "drive_c/ProgramData/Game/save.dat", "drive_c/Program Files/Game/save.dat"] {
            #expect(try Data(contentsOf: prefix.appending(path: relative)) == Data(relative.utf8))
            #expect(try Data(contentsOf: backup.appending(path: "pfx/\(relative)")) == Data(relative.utf8))
        }
        #expect(!fm.fileExists(atPath: prefix.appending(path: "drive_c/windows").path))
        #expect(!fm.fileExists(atPath: prefix.appending(path: "user.reg").path))
        #expect(!fm.fileExists(atPath: parent.appending(path: "synthehol-build").path))
        #expect(try Data(contentsOf: backup.appending(path: "synthehol-build")) == Data("old-runtime".utf8))
        #expect(fm.fileExists(atPath: backup.appending(path: "pfx/user.reg").path))
        #expect(fm.fileExists(atPath: prefix.appending(path: "drive_c/users/steamuser/AppData/Local/Game/save.dat").path))
    }

    @Test func rebuildRefusesOpenPrefixAndLeavesItIntact() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "synthehol-rebuild-busy-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let prefix = root.appending(path: "steamapps/compatdata/620/pfx")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        let file = prefix.appending(path: "user.reg")
        try Data("unchanged".utf8).write(to: file)
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let store = NativeSteamStore(steamRoot: root)
        let game = InstalledGame(store: NativeSteamStore.storeID, storeGameID: "620", name: "Portal 2")
        do {
            _ = try await store.rebuildPrefix(for: game)
            Issue.record("Rebuilt an open prefix")
        } catch PrefixRebuildError.inUse { }
        #expect(try Data(contentsOf: file) == Data("unchanged".utf8))
    }

    @Test func discoversDefaultAndExternalNativeLibraries() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appending(path: "Steam/steamapps")
        let external = root.appending(path: "External/steamapps")
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try nativeManifest(400, "Portal").write(to: primary.appending(path: "appmanifest_400.acf"))
        try nativeManifest(620, "Portal 2").write(to: external.appending(path: "appmanifest_620.acf"))
        try Data("""
        "libraryfolders" { "0" { "path" "\(root.appending(path: "Steam").path)" }
                           "1" { "path" "\(root.appending(path: "External").path)" } }
        """.utf8).write(to: primary.appending(path: "libraryfolders.vdf"))

        let store = NativeSteamStore(
            steamRoot: root.appending(path: "Steam"),
            steamApplication: root.appending(path: "Steam.app")
        )
        let games = try store.installedGames()
        #expect(games.map(\.name) == ["Portal", "Portal 2"])
        #expect(games.map(\.id) == ["native-steam:400", "native-steam:620"])
    }

    @Test func findsPerGameCompatibilityPrefix() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-prefix-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let prefix = root.appending(path: "steamapps/compatdata/620/pfx")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let store = NativeSteamStore(steamRoot: root)
        let game = InstalledGame(store: NativeSteamStore.storeID, storeGameID: "620", name: "Portal 2")
        #expect(store.prefix(for: game) == prefix)
    }

    @Test func locatesPerGameAndClientDiagnosticLogs() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-logs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steamapps = root.appending(path: "Steam/steamapps")
        try FileManager.default.createDirectory(at: steamapps, withIntermediateDirectories: true)
        let support = root.appending(path: "Support")
        let store = NativeSteamStore(steamRoot: root.appending(path: "Steam"))
        let game = InstalledGame(
            store: NativeSteamStore.storeID, storeGameID: "620", name: "Portal 2"
        )

        #expect(store.diagnosticLogs(for: game, support: support) == [
            steamapps.appending(path: "compatdata/620/synthehol-run.log"),
            support.appending(path: "launchers/620/synthehol-wine.log"),
        ])
        #expect(store.clientLog(support: support) == support.appending(path: "synthehol.log"))
    }

    @Test func readsNativeSteamLoginUsers() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-users-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appending(path: "config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try Data(#""users" { "76561198000000001" { "AccountName" "first" "PersonaName" "First" "MostRecent" "0" } "76561198000000002" { "AccountName" "recent" "PersonaName" "Recent" "MostRecent" "1" } }"#.utf8)
            .write(to: config.appending(path: "loginusers.vdf"))

        let users = NativeSteamStore(steamRoot: root).loginUsers()
        #expect(users.map(\.accountName) == ["recent", "first"])
    }
}
