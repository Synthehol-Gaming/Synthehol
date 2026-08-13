import Foundation
import Testing
@testable import SyntheholKit

private func makeStoreEnvironment() throws -> (store: BottleStore, root: URL) {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-bottlestore-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = BottleStore(
        registryURL: root.appending(path: "Bottles.plist"),
        defaultDirectory: root.appending(path: "Bottles")
    )
    return (store, root)
}

struct BottleStoreTests {
    @Test func createRegistersAndListsSortedByName() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try await store.create(name: "zeta")
        _ = try await store.create(name: "Alpha", windowsVersion: .win11)

        let bottles = await store.bottles()
        #expect(bottles.map(\.settings.name) == ["Alpha", "zeta"])
        #expect(bottles[0].settings.windowsVersion == .win11)
    }

    @Test func removeForgetKeepsFilesRemoveDeleteErasesThem() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        let keep = try await store.create(name: "Keep")
        let erase = try await store.create(name: "Erase")

        try await store.remove(keep, deleteFiles: false)
        try await store.remove(erase, deleteFiles: true)

        #expect(await store.bottles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: keep.url.path(percentEncoded: false)))
        #expect(!FileManager.default.fileExists(atPath: erase.url.path(percentEncoded: false)))
    }

    @Test func adoptReAddsForgottenBottleAndDeduplicates() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try await store.create(name: "Wanderer")
        try await store.remove(bottle, deleteFiles: false)
        #expect(await store.bottles().isEmpty)

        try await store.adopt(url: bottle.url)
        try await store.adopt(url: bottle.url) // second adopt must not duplicate
        #expect(await store.bottles().count == 1)
    }

    @Test func renamePersistsAcrossReload() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try await store.create(name: "Before")
        let renamed = try await store.rename(bottle, to: "After")
        #expect(renamed.settings.name == "After")

        let reloaded = try Bottle.load(from: bottle.url)
        #expect(reloaded.settings.name == "After")
    }

    @Test func discoversUnregisteredBottlesInDefaultDirectory() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        // A bottle created outside the store (e.g. by the dev CLI, or after the
        // registry file was lost) must be recovered on next listing.
        let orphan = try Bottle.create(name: "Orphan", in: root.appending(path: "Bottles"))
        _ = orphan
        #expect(await store.bottles().map(\.settings.name) == ["Orphan"])

        // And it is now registered: removing it with deleteFiles works.
        let recovered = try #require(await store.bottles().first)
        try await store.remove(recovered, deleteFiles: true)
        #expect(await store.bottles().isEmpty)
    }

    @Test func missingBottleDirectoriesAreSkippedButNotForgotten() async throws {
        let (store, root) = try makeStoreEnvironment()
        defer { try? FileManager.default.removeItem(at: root) }

        let bottle = try await store.create(name: "Ejected")
        // Simulate an ejected volume: files gone, registry entry intact.
        try FileManager.default.removeItem(at: bottle.url)
        #expect(await store.bottles().isEmpty)

        // "Volume returns": restore metadata at the same path; bottle reappears.
        try FileManager.default.createDirectory(at: bottle.url, withIntermediateDirectories: true)
        try bottle.saveSettings()
        #expect(await store.bottles().map(\.settings.name) == ["Ejected"])
    }
}
