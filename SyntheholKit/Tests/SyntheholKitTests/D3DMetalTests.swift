import Foundation
import Testing
@testable import SyntheholKit

private func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-d3dmetal-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Builds a fake GPTK `redist` layout with the files the importer validates.
private func makeFakeGPTK(at root: URL) throws {
    let fm = FileManager.default
    let wine = root.appending(path: "redist/lib/wine/x86_64-windows")
    let external = root.appending(path: "redist/lib/external")
    try fm.createDirectory(at: wine, withIntermediateDirectories: true)
    try fm.createDirectory(at: external, withIntermediateDirectories: true)
    for dll in ["d3d11.dll", "d3d12.dll", "dxgi.dll"] {
        try Data("fake-\(dll)".utf8).write(to: wine.appending(path: dll))
    }
    try Data("fake-dylib".utf8).write(to: external.appending(path: "libd3dshared.dylib"))
}

/// Serialized: these tests override the shared `importDirectory` and would
/// race each other (and the deployer tests) if run concurrently.
@Suite(.serialized)
struct D3DMetalSupportTests {
    @Test func runtimeCapabilityRejectsBrokenBeta() {
        let stable = WineRuntime(version: "3.1.1", rootDirectory: URL(filePath: "/tmp/r"))
        let brokenBeta = WineRuntime(version: "4.0.0-beta.2", rootDirectory: URL(filePath: "/tmp/r"))
        let wine1115 = WineRuntime(version: "4.5.105-beta.1", rootDirectory: URL(filePath: "/tmp/r"))
        #expect(!D3DMetalSupport.runtimeSupports(stable))
        #expect(!D3DMetalSupport.runtimeSupports(brokenBeta))
        #expect(D3DMetalSupport.runtimeSupports(wine1115))
    }

    @Test func importsFromRedistLayoutAndDetects() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        try makeFakeGPTK(at: temp.appending(path: "GPTK Volume"))

        let saved = D3DMetalSupport.importDirectory
        defer { D3DMetalSupport.importDirectory = saved }
        D3DMetalSupport.importDirectory = temp.appending(path: "Imported")

        #expect(!D3DMetalSupport.isImported)
        try await D3DMetalSupport.importGPTK(from: temp.appending(path: "GPTK Volume"))
        #expect(D3DMetalSupport.isImported)

        // A folder without GPTK content is rejected with a useful error.
        await #expect(throws: D3DMetalSupport.ImportError.self) {
            try await D3DMetalSupport.importGPTK(from: temp.appending(path: "nowhere"))
        }
    }

    /// Apple's outer GPTK volume carries the libraries inside a nested
    /// "Evaluation environment …" disk image; the importer must mount it,
    /// import, and detach transparently.
    @Test func importsFromNestedEvaluationImage() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let payload = temp.appending(path: "payload")
        try makeFakeGPTK(at: payload)
        let outer = temp.appending(path: "Outer Volume")
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: true)
        let create = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/hdiutil"),
            arguments: [
                "create", "-srcfolder", payload.path(percentEncoded: false),
                "-volname", "Evaluation environment test",
                outer.appending(path: "Evaluation environment for Windows games test.dmg")
                    .path(percentEncoded: false)
            ]
        )
        try #require(create.exitCode == 0)

        let saved = D3DMetalSupport.importDirectory
        defer { D3DMetalSupport.importDirectory = saved }
        D3DMetalSupport.importDirectory = temp.appending(path: "Imported")

        try await D3DMetalSupport.importGPTK(from: outer)
        #expect(D3DMetalSupport.isImported)
        // The nested image is detached again after the import.
        #expect(!FileManager.default.fileExists(
            atPath: "/Volumes/Evaluation environment test"
        ))
    }

    @Test func deployerRequiresImportAndCapableRuntime() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let bottle = Bottle(
            url: temp.appending(path: "bottle"), settings: BottleSettings(name: "B")
        )
        try FileManager.default.createDirectory(
            at: bottle.driveC.appending(path: "windows/system32"),
            withIntermediateDirectories: true
        )
        let capable = WineRuntime(
            version: "4.5.105-beta.1", rootDirectory: temp.appending(path: "runtime")
        )

        let saved = D3DMetalSupport.importDirectory
        defer { D3DMetalSupport.importDirectory = saved }
        D3DMetalSupport.importDirectory = temp.appending(path: "Imported")

        // Not imported yet → refuses.
        #expect(throws: GraphicsBackendDeployer.DeployError.self) {
            try GraphicsBackendDeployer.apply(.d3dMetal, runtime: capable, bottle: bottle)
        }

        try makeFakeGPTK(at: temp.appending(path: "vol"))
        try await D3DMetalSupport.importGPTK(from: temp.appending(path: "vol"))

        // The known-broken Wine 10 beta → refuses.
        let beta = WineRuntime(version: "4.0.0-beta.2", rootDirectory: temp.appending(path: "runtime"))
        #expect(throws: GraphicsBackendDeployer.DeployError.self) {
            try GraphicsBackendDeployer.apply(.d3dMetal, runtime: beta, bottle: bottle)
        }
    }

    @Test func deploysShimsExternalsAndProfileSymlink() async throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default

        let bottle = Bottle(
            url: temp.appending(path: "bottle"), settings: BottleSettings(name: "B")
        )
        let system32 = bottle.driveC.appending(path: "windows/system32")
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        try Data("builtin".utf8).write(to: system32.appending(path: "d3d11.dll"))
        let profile = bottle.driveC.appending(path: "users/tester")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)

        let runtime = WineRuntime(
            version: "4.5.105-beta.1", rootDirectory: temp.appending(path: "runtime")
        )
        try fm.createDirectory(
            at: runtime.librariesDirectory.appending(path: "Wine/lib"),
            withIntermediateDirectories: true
        )
        let runtimeWindows = runtime.librariesDirectory.appending(
            path: "Wine/lib/wine/x86_64-windows"
        )
        try fm.createDirectory(at: runtimeWindows, withIntermediateDirectories: true)
        try Data("runtime-builtin".utf8).write(
            to: runtimeWindows.appending(path: "d3d11.dll")
        )
        let steamCEF = bottle.driveC.appending(
            path: "Program Files (x86)/Steam/bin/cef/cef.win64"
        )
        try fm.createDirectory(at: steamCEF, withIntermediateDirectories: true)
        let dxvk64 = runtime.dxvkDirectory.appending(path: "x64")
        try fm.createDirectory(at: dxvk64, withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll"] {
            try Data("DXVK-\(dll)".utf8).write(to: dxvk64.appending(path: dll))
        }
        let dxmt64 = runtime.librariesDirectory.appending(path: "DXMT/x64")
        try fm.createDirectory(at: dxmt64, withIntermediateDirectories: true)
        for dll in ["d3d10core.dll", "d3d11.dll", "dxgi.dll"] {
            try Data("DXMT-\(dll)".utf8).write(to: dxmt64.appending(path: dll))
        }
        // Simulate the previous deployment so the v4 repair proves it removes
        // the mixed DXVK/D3DMetal stack and restores Steam's original file.
        try Data("DXVK-x64".utf8).write(to: steamCEF.appending(path: "d3d11.dll"))
        try Data("steam-original".utf8).write(
            to: steamCEF.appending(path: "d3d11.dll.synthehol-orig")
        )
        // A repeated old repair may leave a DXVK file with no useful backup.
        try Data("DXVK-d3d10core.dll".utf8).write(
            to: steamCEF.appending(path: "d3d10core.dll")
        )

        let saved = D3DMetalSupport.importDirectory
        defer { D3DMetalSupport.importDirectory = saved }
        D3DMetalSupport.importDirectory = temp.appending(path: "Imported")
        try makeFakeGPTK(at: temp.appending(path: "vol"))
        try await D3DMetalSupport.importGPTK(from: temp.appending(path: "vol"))

        #expect(GraphicsBackendDeployer.d3dMetalNeedsRepair(in: bottle))
        try GraphicsBackendDeployer.apply(.d3dMetal, runtime: runtime, bottle: bottle)
        #expect(!GraphicsBackendDeployer.d3dMetalNeedsRepair(in: bottle))

        // Apple's PE half is a Wine builtin module and belongs in the runtime,
        // not system32. The prefix remains untouched.
        let systemDLL = try String(
            contentsOf: system32.appending(path: "d3d11.dll"), encoding: .utf8
        )
        #expect(systemDLL == "builtin")
        #expect(try String(
            contentsOf: runtimeWindows.appending(path: "d3d11.dll"),
            encoding: .utf8
        ) == "fake-d3d11.dll")
        #expect(try String(
            contentsOf: runtimeWindows.appending(path: "d3d11.dll.synthehol-orig"),
            encoding: .utf8
        ) == "runtime-builtin")
        // Steam's CEF process gets only the app-local DXVK D3D11 pair.
        #expect(try String(
            contentsOf: steamCEF.appending(path: "d3d11.dll"), encoding: .utf8
        ) == "DXVK-d3d11.dll")
        #expect(try String(
            contentsOf: steamCEF.appending(path: "d3d10core.dll"), encoding: .utf8
        ) == "DXVK-d3d10core.dll")
        #expect(!fm.fileExists(
            atPath: steamCEF.appending(path: "dxgi.dll").path(percentEncoded: false)
        ))
        #expect(try String(
            contentsOf: steamCEF.appending(path: "d3d11.dll.synthehol-orig"),
            encoding: .utf8
        ) == "steam-original")
        // Mac-side dylib landed in the runtime's external dir.
        #expect(fm.fileExists(
            atPath: runtime.librariesDirectory
                .appending(path: "Wine/lib/external/libd3dshared.dylib")
                .path(percentEncoded: false)
        ))
        // Unix-side D3D entry points are relative symlinks into external/
        // (per the runtime's README; copies would break @loader_path).
        for so in ["d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so"] {
            let link = runtime.librariesDirectory
                .appending(path: "Wine/lib/wine/x86_64-unix/\(so)")
                .path(percentEncoded: false)
            #expect(try fm.destinationOfSymbolicLink(atPath: link)
                == "../../external/libd3dshared.dylib")
        }
        // CrossOver profile symlink points at the existing profile, relatively.
        let link = bottle.driveC.appending(path: "users/crossover")
        #expect(try fm.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        ) == "tester")
        #expect(GraphicsBackendDeployer.dllOverrides(for: .d3dMetal) == nil)

        // Switching away restores the original DLL.
        try GraphicsBackendDeployer.restoreOriginals(in: bottle)
        let restored = try String(
            contentsOf: system32.appending(path: "d3d11.dll"), encoding: .utf8
        )
        #expect(restored == "builtin")
    }
}
