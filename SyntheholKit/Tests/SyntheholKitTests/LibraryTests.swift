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
