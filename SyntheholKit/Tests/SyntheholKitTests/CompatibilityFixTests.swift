import Foundation
import CryptoKit
import Testing
@testable import SyntheholKit

private struct FixFixture {
    let root: URL
    let prefix: URL
    let executable: URL
    let packageDirectory: URL
    let game: InstalledGame
    let store: CompatibilityFixStore
    let package = CompatibilityFixPackage(fixID: "test-fix", version: "v1")

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "synthehol-fix-\(UUID())")
        prefix = root.appending(path: "pfx")
        executable = root.appending(path: "Game/test.exe")
        packageDirectory = root.appending(path: "Package")
        let fm = FileManager.default
        for directory in [prefix.appending(path: "drive_c/windows/system32"), executable.deletingLastPathComponent(), packageDirectory] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var exe = Data(repeating: 0, count: 70)
        exe[0] = 0x4d; exe[1] = 0x5a; exe[0x3c] = 64
        exe[64] = 0x50; exe[65] = 0x45; exe[68] = 0x64; exe[69] = 0x86
        try exe.write(to: executable)
        try Data("bridge".utf8).write(to: prefix.appending(path: "drive_c/windows/system32/winemetal.dll"))
        let key = "Software\\\\Wine\\\\AppDefaults\\\\test.exe\\\\DllOverrides"
        try "WINE REGISTRY Version 2\n\n[\(key)]\n\"d3d11\"=\"builtin\"\n\"custom\"=\"native\"\n"
            .write(to: prefix.appending(path: "user.reg"), atomically: true, encoding: .utf8)
        try Data("original".utf8).write(to: executable.deletingLastPathComponent().appending(path: "d3d11.dll"))
        try Data("patched".utf8).write(to: packageDirectory.appending(path: "d3d11.dll"))
        try JSONEncoder().encode(package).write(to: packageDirectory.appending(path: "FixPackage.json"))
        func hash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
        let fix = CompatibilityFix(id: "test-fix", title: "Test", symptom: "Test", validation: "Test",
            source: URL(string: "https://example.com")!, steamAppIDs: ["1"],
            versions: [.init(id: "v1", files: ["d3d11.dll": hash("patched")], wineMetalSHA256: hash("bridge"))])
        store = CompatibilityFixStore(root: root.appending(path: "Managed"), catalog: [fix])
        game = InstalledGame(store: SteamStore.storeID, storeGameID: "1", name: "Test", installPath: executable.deletingLastPathComponent().path)
    }
    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

struct CompatibilityFixTests {
    @Test func recommendationsDoNotMatchUnrelatedStoresOrGames() {
        let skyrim = InstalledGame(store: NativeSteamStore.storeID, storeGameID: "489830", name: "Skyrim")
        let other = InstalledGame(store: SteamStore.storeID, storeGameID: "1", name: "Other")
        let custom = InstalledGame(store: "custom", storeGameID: "489830", name: "Custom")
        #expect(CompatibilityFixCatalog.recommendations(for: skyrim).count == 1)
        #expect(CompatibilityFixCatalog.recommendations(for: other).isEmpty)
        #expect(CompatibilityFixCatalog.recommendations(for: custom).isEmpty)
    }

    @Test func importingNeverAppliesAFix() async throws {
        let f = try FixFixture(); defer { f.cleanUp() }
        let registry = try Data(contentsOf: f.prefix.appending(path: "user.reg"))
        try Data("license notice".utf8).write(to: f.packageDirectory.appending(path: "LICENSE"))
        _ = try await f.store.importPackage(at: f.packageDirectory)
        #expect(await f.store.isImported(f.package))
        #expect(await f.store.applications(for: f.game, prefix: f.prefix).isEmpty)
        #expect(try Data(contentsOf: f.prefix.appending(path: "user.reg")) == registry)
        #expect(try Data(contentsOf: f.root.appending(path: "Managed/Versions/test-fix/v1/LICENSE")) == Data("license notice".utf8))
        #expect(try Data(contentsOf: f.executable.deletingLastPathComponent().appending(path: "d3d11.dll")) == Data("original".utf8))
    }

    @Test func rejectsTamperedPackagesBeforeImport() async throws {
        let f = try FixFixture(); defer { f.cleanUp() }
        try Data("tampered".utf8).write(to: f.packageDirectory.appending(path: "d3d11.dll"))
        do { _ = try await f.store.importPackage(at: f.packageDirectory); Issue.record("Imported invalid DLL") }
        catch CompatibilityFixError.checksum { }
        #expect(!(await f.store.isImported(f.package)))
    }

    @Test func manualApplyAndRemoveRestoreFilesAndKeepUnrelatedRegistryChanges() async throws {
        let f = try FixFixture(); defer { f.cleanUp() }
        _ = try await f.store.importPackage(at: f.packageDirectory)
        let receipt = try await f.store.apply(f.package, to: f.game, executable: f.executable, prefix: f.prefix)
        let dll = f.executable.deletingLastPathComponent().appending(path: "d3d11.dll")
        #expect(try Data(contentsOf: dll) == Data("patched".utf8))
        #expect(await f.store.applications(for: f.game, prefix: f.prefix).count == 1)
        #expect(!FileManager.default.fileExists(atPath: f.prefix.appending(path: "drive_c/windows/system32/d3d11.dll").path))
        let reg = f.prefix.appending(path: "user.reg")
        var text = try String(contentsOf: reg, encoding: .utf8)
        #expect(text.contains("\"d3d11\"=\"native,builtin\""))
        text += "\n[Software\\\\Other]\n\"value\"=\"later\"\n"
        try text.write(to: reg, atomically: true, encoding: .utf8)
        try await f.store.remove(receipt)
        #expect(try Data(contentsOf: dll) == Data("original".utf8))
        let restored = try String(contentsOf: reg, encoding: .utf8)
        #expect(restored.contains("\"d3d11\"=\"builtin\""))
        #expect(restored.contains("\"custom\"=\"native\""))
        #expect(restored.contains("\"value\"=\"later\""))
        #expect(!restored.contains("\"winemetal\"="))
        #expect(await f.store.applications(for: f.game, prefix: f.prefix).isEmpty)
    }

    @Test func refusesRemovalIfUserChangedInstalledDLL() async throws {
        let f = try FixFixture(); defer { f.cleanUp() }
        _ = try await f.store.importPackage(at: f.packageDirectory)
        let receipt = try await f.store.apply(f.package, to: f.game, executable: f.executable, prefix: f.prefix)
        let dll = f.executable.deletingLastPathComponent().appending(path: "d3d11.dll")
        try Data("user replacement".utf8).write(to: dll)
        do { try await f.store.remove(receipt); Issue.record("Overwrote user's replacement") }
        catch CompatibilityFixError.modifiedFiles { }
        #expect(try Data(contentsOf: dll) == Data("user replacement".utf8))
    }

    @Test func refusesMismatchedWineBridgeAndExecutableOutsideGame() async throws {
        let f = try FixFixture(); defer { f.cleanUp() }
        _ = try await f.store.importPackage(at: f.packageDirectory)
        try Data("wrong".utf8).write(to: f.prefix.appending(path: "drive_c/windows/system32/winemetal.dll"))
        do { _ = try await f.store.apply(f.package, to: f.game, executable: f.executable, prefix: f.prefix); Issue.record("Accepted wrong bridge") }
        catch CompatibilityFixError.incompatibleBridge { }
        let outside = f.root.appending(path: "outside.exe")
        try FileManager.default.copyItem(at: f.executable, to: outside)
        do { _ = try await f.store.apply(f.package, to: f.game, executable: outside, prefix: f.prefix); Issue.record("Accepted unrelated executable") }
        catch CompatibilityFixError.invalidExecutable { }
    }
}
