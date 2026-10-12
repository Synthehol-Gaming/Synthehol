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
