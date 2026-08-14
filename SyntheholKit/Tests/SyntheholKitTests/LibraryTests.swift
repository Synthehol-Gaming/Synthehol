import Foundation
import Testing
@testable import SyntheholKit

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let portal2 = InstalledGame(
    store: "steam", storeGameID: "620", name: "Portal 2",
    posterURL: URL(string: "https://example.invalid/620.jpg")
)

struct GameSettingsTests {
    @Test func roundtripsPerGamePerBottle() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))

        var settings = GameSettings()
        settings.launchArguments = "-novid  -fullscreen"
        settings.environment = ["MTL_HUD_ENABLED": "1"]
        try settings.save(for: portal2, in: bottle)

        let loaded = GameSettings.load(for: portal2, in: bottle)
        #expect(loaded == settings)
        #expect(loaded.launchArgumentList == ["-novid", "-fullscreen"])

        // Same appid in a different store must not collide.
        let gogTwin = InstalledGame(store: "gog", storeGameID: "620", name: "Other")
        #expect(GameSettings.load(for: gogTwin, in: bottle) == GameSettings())
    }

    @Test func missingSettingsLoadAsDefaults() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))
        #expect(GameSettings.load(for: portal2, in: bottle) == GameSettings())
    }

    /// Plists written before `nudgeStuckLoading` existed must load with their
    /// values intact, not reset to defaults (lenient-decode convention).
    @Test func decodesLegacyPlistWithoutNudgeKey() throws {
        let legacy = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
        "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
            <key>launchArguments</key><string>-novid</string>
            <key>environment</key><dict/>
        </dict></plist>
        """
        let settings = try PropertyListDecoder().decode(
            GameSettings.self, from: Data(legacy.utf8)
        )
        #expect(settings.launchArguments == "-novid")
        #expect(settings.nudgeStuckLoading == false)
    }

    @Test func roundtripsNudgeSetting() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))
        try GameSettings(nudgeStuckLoading: true).save(for: portal2, in: bottle)
        #expect(GameSettings.load(for: portal2, in: bottle).nudgeStuckLoading)
    }
}

struct GameNudgerTests {
    @Test func processPatternEscapesAndRequiresInstallPath() {
        let game = InstalledGame(
            store: "steam", storeGameID: "620", name: "P2",
            posterURL: nil, installPath: "Portal 2 (Beta+)"
        )
        let pattern = GameNudger.processPattern(for: game)
        #expect(pattern == "steamapps.common.Portal 2 \\(Beta\\+\\).")
        #expect(GameNudger.processPattern(for: portal2) == nil)
    }
}

struct SteamMetadataTests {
    private let fixture = Data("""
    {"620": {"success": true, "data": {
        "short_description": "Portals again.",
        "genres": [{"id": "1", "description": "Action"}, {"id": "25", "description": "Adventure"}],
        "categories": [{"id": 2, "description": "Single-player"}, {"id": 9, "description": "Co-op"}],
        "release_date": {"coming_soon": false, "date": "18 Apr, 2011"}
    }}}
    """.utf8)

    @Test func parsesAppDetailsResponse() {
        let meta = SteamMetadataStore.parse(fixture, appID: "620")
        #expect(meta?.genres == ["Action", "Adventure"])
        #expect(meta?.categories == ["Single-player", "Co-op"])
        #expect(meta?.shortDescription == "Portals again.")
        #expect(meta?.releaseDate == "18 Apr, 2011")
    }

    @Test func parseRejectsFailureAndWrongID() {
        #expect(SteamMetadataStore.parse(fixture, appID: "999") == nil)
        let failure = Data(#"{"620": {"success": false}}"#.utf8)
        #expect(SteamMetadataStore.parse(failure, appID: "620") == nil)
    }

    @Test func servesFromDiskCacheWithoutNetwork() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cached = SteamAppMetadata(genres: ["Action"], categories: ["Co-op"])
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try JSONEncoder().encode(cached).write(to: temp.appending(path: "620.json"))

        // An unusable session proves the answer came from disk, not network.
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []
        let store = SteamMetadataStore(directory: temp, urlSession: URLSession(configuration: config))
        #expect(await store.metadata(forAppID: "620") == cached)
    }
}

struct ArtworkCacheTests {
    @Test func returnsCachedDataWithoutFetching() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let cache = ArtworkCache(directory: temp)
        let cacheFile = await cache.cacheFile(forGameID: portal2.id)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try Data("poster-bytes".utf8).write(to: cacheFile)

        let data = await cache.poster(for: portal2, remoteCandidates: [])
        #expect(data == Data("poster-bytes".utf8))
    }

    @Test func fallsBackToLocalArtworkAndCachesIt() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        let localArt = temp.appending(path: "librarycache-poster.jpg")
        try Data("local-art".utf8).write(to: localArt)

        let cacheDir = temp.appending(path: "Artwork")
        let cache = ArtworkCache(directory: cacheDir)
        // No remotes (empty list) — must use the local fallback and cache it.
        let data = await cache.poster(for: portal2, remoteCandidates: [], localFallbacks: [localArt])
        #expect(data == Data("local-art".utf8))

        let cached = FileManager.default.contents(
            atPath: (await cache.cacheFile(forGameID: portal2.id)).path(percentEncoded: false)
        )
        #expect(cached == Data("local-art".utf8))
    }

    @Test func customPosterOverridesAndResetRefetches() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = ArtworkCache(directory: temp)

        try await cache.setCustomPoster(Data("my-art".utf8), forGameID: portal2.id)
        let custom = await cache.poster(for: portal2, remoteCandidates: [])
        #expect(custom == Data("my-art".utf8))

        await cache.resetPoster(forGameID: portal2.id)
        let localArt = temp.appending(path: "fallback.jpg")
        try Data("default-art".utf8).write(to: localArt)
        let refetched = await cache.poster(
            for: portal2, remoteCandidates: [], localFallbacks: [localArt]
        )
        #expect(refetched == Data("default-art".utf8))
    }

    @Test func missingEverywhereReturnsNil() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let cache = ArtworkCache(directory: temp)
        let data = await cache.poster(
            for: portal2, remoteCandidates: [],
            localFallbacks: [temp.appending(path: "nope.jpg")]
        )
        #expect(data == nil)
    }
}

struct SteamArtworkTests {
    @Test func remoteCandidatesPreferHighResPoster() {
        let candidates = SteamStore().remoteArtworkCandidates(for: portal2)
        #expect(candidates.map(\.lastPathComponent) ==
            ["library_600x900_2x.jpg", "library_600x900.jpg", "header.jpg"])
        #expect(candidates.allSatisfy { $0.absoluteString.contains("/620/") })
    }

    @Test func localFallbacksPointIntoBottleLibrarycache() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(url: temp, settings: BottleSettings(name: "B"))
        let fallbacks = SteamStore().localArtworkFallbacks(for: portal2, in: bottle)
        #expect(fallbacks.first?.path(percentEncoded: false).hasSuffix(
            "appcache/librarycache/620/library_600x900.jpg") == true)
    }
}
