import CryptoKit
import Foundation
import Testing
@testable import SyntheholKit

/// Builds a fake runtime tarball (Libraries/Wine/bin/{wine64,wineserver}) and
/// returns its file URL and SHA-256.
private func makeFixtureTarball(in directory: URL) throws -> (url: URL, sha256: String) {
    let payload = directory.appending(path: "payload")
    let bin = payload.appending(path: "Libraries/Wine/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    for name in ["wine64", "wineserver"] {
        let file = bin.appending(path: name)
        try Data("#!/bin/sh\necho fake-\(name)\n".utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false)
        )
    }
    let tarball = directory.appending(path: "Libraries.tar.gz")
    let tar = Process()
    tar.executableURL = URL(filePath: "/usr/bin/tar")
    tar.arguments = ["-czf", tarball.path(percentEncoded: false),
                     "-C", payload.path(percentEncoded: false), "Libraries"]
    try tar.run()
    tar.waitUntilExit()
    try #require(tar.terminationStatus == 0)

    let digest = SHA256.hash(data: try Data(contentsOf: tarball))
    return (tarball, digest.map { String(format: "%02x", $0) }.joined())
}

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct RuntimeStoreTests {
    @Test func installsVerifiedArchiveAndActivatesIt() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = try makeFixtureTarball(in: temp)

        let root = temp.appending(path: "Runtime")
        let store = RuntimeStore(rootDirectory: root)
        let manifest = RuntimeManifest(
            version: "9.9.9", url: fixture.url, sha256: fixture.sha256
        )

        let runtime = try await store.install(manifest)
        #expect(runtime.isValid)
        #expect(runtime.version == "9.9.9")
        #expect(await store.installedVersions() == ["9.9.9"])
        #expect(await store.current()?.version == "9.9.9")

        // No staging leftovers.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { $0.hasPrefix(".staging") }
        #expect(leftovers.isEmpty)
    }

    @Test func rejectsChecksumMismatchAndInstallsNothing() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = try makeFixtureTarball(in: temp)

        let root = temp.appending(path: "Runtime")
        let store = RuntimeStore(rootDirectory: root)
        let manifest = RuntimeManifest(
            version: "6.6.6", url: fixture.url,
            sha256: String(repeating: "ab", count: 32)
        )

        await #expect(throws: RuntimeStoreError.self) {
            try await store.install(manifest)
        }
        #expect(await store.installedVersions().isEmpty)
        #expect(await store.current() == nil)
    }

    @Test func rejectsArchiveWithWrongLayout() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        // A tarball with no Libraries/Wine/bin inside.
        let payload = temp.appending(path: "payload/NotLibraries")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: payload.appending(path: "file.txt"))
        let tarball = temp.appending(path: "bad.tar.gz")
        let tar = Process()
        tar.executableURL = URL(filePath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path(percentEncoded: false),
                         "-C", temp.appending(path: "payload").path(percentEncoded: false),
                         "NotLibraries"]
        try tar.run()
        tar.waitUntilExit()
        let digest = SHA256.hash(data: try Data(contentsOf: tarball))
        let sha = digest.map { String(format: "%02x", $0) }.joined()

        let store = RuntimeStore(rootDirectory: temp.appending(path: "Runtime"))
        await #expect(throws: RuntimeStoreError.invalidArchiveLayout(missing: "Libraries/Wine/bin/wine64")) {
            try await store.install(RuntimeManifest(version: "1.0.0", url: tarball, sha256: sha))
        }
        #expect(await store.installedVersions().isEmpty)
    }

    @Test func keepsPreviousVersionForRollbackAndPrunesOlder() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = try makeFixtureTarball(in: temp)

        let store = RuntimeStore(rootDirectory: temp.appending(path: "Runtime"))
        for version in ["1.0.0", "2.0.0", "3.0.0"] {
            try await store.install(RuntimeManifest(
                version: version, url: fixture.url, sha256: fixture.sha256
            ))
        }
        #expect(await store.installedVersions() == ["2.0.0", "3.0.0"])
        #expect(await store.current()?.version == "3.0.0")
    }

    @Test func installsLocalSidecarWithTheSameChecksumVerification() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = try makeFixtureTarball(in: temp)
        let sidecar = temp.appending(path: "performance.json")
        let manifest = LocalRuntimeManifest(
            version: "performance-test", archive: fixture.url.lastPathComponent,
            sha256: fixture.sha256
        )
        try JSONEncoder().encode(manifest).write(to: sidecar)

        let store = RuntimeStore(rootDirectory: temp.appending(path: "Runtime"))
        let runtime = try await store.installLocalManifest(at: sidecar)
        #expect(runtime.version == "performance-test")
        #expect(await store.current()?.version == "performance-test")
    }

    @Test func rejectsUnsafeRuntimeVersion() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fixture = try makeFixtureTarball(in: temp)
        let store = RuntimeStore(rootDirectory: temp.appending(path: "Runtime"))
        await #expect(throws: RuntimeStoreError.invalidVersion("../escape")) {
            try await store.install(RuntimeManifest(
                version: "../escape", url: fixture.url, sha256: fixture.sha256
            ))
        }
    }
}

struct WineExecutorTests {
    @Test func environmentMergesBaseSettingsAndExtras() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        var settings = BottleSettings(name: "Env")
        settings.enhancedSync = .msync
        settings.metalHUD = true
        let bottle = Bottle(url: temp, settings: settings)
        let executor = WineExecutor(runtime: WineRuntime(version: "0", rootDirectory: temp))

        let env = executor.environment(for: bottle, extra: ["LC_ALL": "ja_JP.UTF-8"])
        #expect(env["WINEPREFIX"] == temp.path(percentEncoded: false))
        #expect(env["WINEDEBUG"] == "fixme-all")
        #expect(env["WINEMSYNC"] == "1")
        #expect(env["WINEESYNC"] == "1")
        #expect(env["MTL_HUD_ENABLED"] == "1")
        #expect(env["LC_ALL"] == "ja_JP.UTF-8")
    }
}

struct PerformanceRuntimeCapabilitiesTests {
    @Test func requiresValidCompleteV1Manifest() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let marker = temp.appending(
            path: "Libraries/Wine/share/synthehol/performance-capabilities.json"
        )
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let runtime = WineRuntime(version: "performance", rootDirectory: temp)
        try Data("{\"schemaVersion\":1,\"implementation\":\"test\",\"features\":[]}".utf8)
            .write(to: marker)
        #expect(!runtime.supportsPerformanceProfiles)

        let capabilities = PerformanceRuntimeCapabilities(
            schemaVersion: 1, implementation: "test",
            features: PerformanceRuntimeCapabilities.requiredV1Features
        )
        try JSONEncoder().encode(capabilities).write(to: marker)
        #expect(runtime.supportsPerformanceProfiles)
    }
}

struct BottleTests {
    @Test func createSaveLoadRoundtrip() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        var bottle = try Bottle.create(name: "Steam Bottle", in: temp)
        bottle.settings.steamInstalled = true
        try bottle.saveSettings()

        let loaded = try Bottle.load(from: bottle.url)
        #expect(loaded.settings.name == "Steam Bottle")
        #expect(loaded.settings.steamInstalled)
        #expect(!loaded.prefixExists)
    }
}
