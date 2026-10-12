import Foundation
import Testing
@testable import SyntheholKit

private func makeNativePayload(at root: URL) throws -> NativeSteamPayload {
    try FileManager.default.createDirectory(
        at: root.appending(path: "signatures/macos.arm64"),
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: root.appending(path: "bridge"), withIntermediateDirectories: true
    )
    for name in [NativeSteamPayload.dylibName, NativeSteamPayload.overlayShimName, "run"] {
        try Data(name.utf8).write(to: root.appending(path: name))
    }
    try Data("{}".utf8).write(to: root.appending(path: "signatures/macos.arm64/test.json"))
    for name in [
        "steam.exe", "x86_64-windows-lsteamclient.dll",
        "x86_64-unix-lsteamclient.so", "i386-windows-lsteamclient.dll"
    ] {
        try Data(name.utf8).write(to: root.appending(path: "bridge/\(name)"))
    }
    return try NativeSteamPayload(root: root)
}

private func makeFakeSteam(at app: URL) throws {
    try FileManager.default.createDirectory(
        at: app.appending(path: "Contents/MacOS"), withIntermediateDirectories: true
    )
    try Data("steam".utf8).write(to: app.appending(path: "Contents/MacOS/steam_osx"))
    let info: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam"]
    let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try data.write(to: app.appending(path: "Contents/Info.plist"))
}

private func makeFakeRuntime(at root: URL) throws -> WineRuntime {
    let bin = root.appending(path: "Libraries/Wine/bin")
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: root.appending(path: "Libraries/Wine/lib/wine"), withIntermediateDirectories: true
    )
    for name in ["wine64", "wineserver"] {
        let file = bin.appending(path: name)
        try Data(name.utf8).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: file.path
        )
    }
    return WineRuntime(version: "test-1.0", rootDirectory: root)
}

private func makeFakeSteamBottle(at root: URL) throws -> Bottle {
    var settings = BottleSettings(name: "Steam Source")
    settings.steamInstalled = true
    let bottle = Bottle(url: root, settings: settings)
    let steam = bottle.driveC.appending(path: "Program Files (x86)/Steam")
    try FileManager.default.createDirectory(at: steam, withIntermediateDirectories: true)
    for (name, machine) in NativeSteamBridgeProvisioner.requiredFiles {
        var data = Data(repeating: 0, count: 70)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 64
        data[64] = 0x50
        data[65] = 0x45
        data[68] = UInt8(machine & 0xff)
        data[69] = UInt8(machine >> 8)
        try data.write(to: steam.appending(path: name))
    }
    return bottle
}

private let fakeRunnerProvisioner: @Sendable (WineRuntime, URL, URL) async throws -> Void = {
    runtime, support, _ in
    let runner = support.appending(path: "runners/crossover-\(runtime.version)/CrossOver")
    try FileManager.default.createDirectory(at: runner.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: runner, withDestinationURL: runtime.librariesDirectory.appending(path: "Wine")
    )
}

struct NativeSteamInstallerTests {
    @Test func stagesPairedD3DMetalModulesWithoutReplacingSharedDXGI() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "synthehol-metal-modules-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let clone = root.appending(path: "D3DMetal")
        let source = root.appending(path: "import")
        let shared = root.appending(path: "CrossOver/lib/wine/x86_64-windows/dxgi.dll")
        let external = clone.appending(path: "lib/external/libd3dshared.dylib")
        for directory in [source, shared.deletingLastPathComponent(), external.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try Data("stock".utf8).write(to: shared)
        try Data("unix-bridge".utf8).write(to: external)
        for name in ["dxgi", "d3d11", "d3d12"] {
            try Data(name.utf8).write(to: source.appending(path: "\(name).dll"))
        }
        try NativeSteamInstaller.stageD3DMetalModules(in: clone, from: source)
        try NativeSteamInstaller.stageD3DMetalModules(in: clone, from: source)
        #expect(try Data(contentsOf: shared) == Data("stock".utf8))
        for name in ["dxgi", "d3d11", "d3d12"] {
            #expect(try Data(contentsOf: clone.appending(path: "lib/wine/x86_64-windows/\(name).dll")) == Data(name.utf8))
            #expect(try Data(contentsOf: clone.appending(path: "lib/wine/x86_64-unix/\(name).so")) == Data("unix-bridge".utf8))
        }
    }

    @Test func installsOwnedPayloadAndCanRepairSteam() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-installer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Steam.app")
        let support = root.appending(path: "Support")
        let payload = try makeNativePayload(at: root.appending(path: "Payload"))
        let runtime = try makeFakeRuntime(at: root.appending(path: "Runtime/test-1.0"))
        let bottle = try makeFakeSteamBottle(at: root.appending(path: "Bottle"))
        try makeFakeSteam(at: app)

        try await NativeSteamInstaller.install(
            payload: payload, steamApplication: app, support: support, runtime: runtime,
            bottles: [bottle],
            runnerProvisioner: fakeRunnerProvisioner,
            sign: { _ in }
        )
        let installed = try Data(contentsOf: app.appending(
            path: "Contents/MacOS/\(NativeSteamPayload.dylibName)"
        ))
        #expect(installed == Data(NativeSteamPayload.dylibName.utf8))
        #expect(FileManager.default.fileExists(atPath: support.appending(path: "deployment.json").path))
        #expect(FileManager.default.fileExists(atPath: support.appending(
            path: NativeSteamInstaller.backupName
        ).path))
        #expect(!FileManager.default.fileExists(atPath: app.appending(
            path: "Contents/Info.plist.before-synthehol-steamplay"
        ).path))
        #expect(FileManager.default.fileExists(atPath: support.appending(
            path: "bridge/x86_64-unix/lsteamclient.so"
        ).path))
        #expect(try String(contentsOf: support.appending(path: "tools"), encoding: .utf8)
            == "synthehol-proton-test-1.0\ttest-1.0\trosetta\tSynthehol Steam Play (test-1.0)\n")
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: support.appending(path: "runners/crossover-test-1.0/CrossOver").path
        ) == runtime.librariesDirectory.appending(path: "Wine").path)
        var status = NativeSteamCompatibilityStatus.inspect(
            steamApplication: app, support: support
        )
        #expect(status.deployment == .installed)
        #expect(status.runnerVersion == "test-1.0")
        #expect(!status.performanceProfilesAvailable)

        let marker = runtime.performanceCapabilities
        try FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let capabilities = PerformanceRuntimeCapabilities(
            schemaVersion: 1, implementation: "test",
            features: PerformanceRuntimeCapabilities.requiredV1Features
        )
        try JSONEncoder().encode(capabilities).write(to: marker)
        status = NativeSteamCompatibilityStatus.inspect(
            steamApplication: app, support: support
        )
        #expect(status.performanceProfilesAvailable)

        let plistData = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let plist = try #require(
            PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        )
        let environment = try #require(plist[NativeSteamInstaller.environmentKey] as? [String: Any])
        #expect((environment[NativeSteamInstaller.insertKey] as? String)?.hasSuffix(
            NativeSteamPayload.dylibName
        ) == true)

        try await NativeSteamInstaller.repair(
            steamApplication: app, support: support, sign: { _ in }
        )
        let repairedData = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        let repaired = try #require(
            PropertyListSerialization.propertyList(from: repairedData, format: nil) as? [String: Any]
        )
        #expect(repaired[NativeSteamInstaller.environmentKey] == nil)
    }

    @Test func migratesLegacyInBundleBackupBeforeSigning() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Steam.app")
        let support = root.appending(path: "Support")
        let payload = try makeNativePayload(at: root.appending(path: "Payload"))
        let runtime = try makeFakeRuntime(at: root.appending(path: "Runtime/test-1.0"))
        let bottle = try makeFakeSteamBottle(at: root.appending(path: "Bottle"))
        try makeFakeSteam(at: app)
        let legacy = app.appending(path: "Contents/Info.plist.before-synthehol-steamplay")
        let original = try Data(contentsOf: app.appending(path: "Contents/Info.plist"))
        try original.write(to: legacy)

        try await NativeSteamInstaller.install(
            payload: payload, steamApplication: app, support: support, runtime: runtime,
            bottles: [bottle],
            runnerProvisioner: fakeRunnerProvisioner,
            sign: { target in
                #expect(!FileManager.default.fileExists(atPath: legacy.path))
                #expect(FileManager.default.fileExists(atPath: target.path))
            }
        )

        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(try Data(contentsOf: support.appending(
            path: NativeSteamInstaller.backupName
        )) == original)
    }

    @Test func refusesForeignInjection() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "synthehol-native-foreign-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appending(path: "Steam.app")
        let payload = try makeNativePayload(at: root.appending(path: "Payload"))
        let runtime = try makeFakeRuntime(at: root.appending(path: "Runtime/test-1.0"))
        let bottle = try makeFakeSteamBottle(at: root.appending(path: "Bottle"))
        try makeFakeSteam(at: app)
        let info: [String: Any] = [
            "LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/tmp/other.dylib"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))

        await #expect(throws: NativeSteamInstallError.self) {
            try await NativeSteamInstaller.install(
                payload: payload, steamApplication: app, support: root.appending(path: "Support"),
                runtime: runtime, bottles: [bottle],
                sign: { _ in }
            )
        }
    }
}
