import Foundation
import Testing
@testable import SyntheholKit

private struct Fixture {
    let runtime: WineRuntime
    let bottle: Bottle
    let root: URL
    let system32: URL
    let syswow64: URL
}

private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "synthehol-gfx-\(UUID().uuidString)")
    let fm = FileManager.default

    // Fake runtime with DXMT and DXVK payloads.
    let libraries = root.appending(path: "Runtime/Libraries")
    for (backend, dlls) in [
        ("DXMT", ["d3d11.dll", "dxgi.dll", "winemetal.dll"]),
        ("DXVK", ["d3d11.dll", "d3d10core.dll"])
    ] {
        for arch in ["x64", "x32"] {
            let dir = libraries.appending(path: "\(backend)/\(arch)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for dll in dlls {
                try Data("\(backend)-\(arch)-\(dll)".utf8).write(to: dir.appending(path: dll))
            }
        }
    }

    // Fake prefix with builtin DLLs.
    let bottleDir = root.appending(path: "Bottle")
    let system32 = bottleDir.appending(path: "drive_c/windows/system32")
    let syswow64 = bottleDir.appending(path: "drive_c/windows/syswow64")
    for dir in [system32, syswow64] {
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for dll in ["d3d11.dll", "dxgi.dll"] {
            try Data("builtin-\(dll)".utf8).write(to: dir.appending(path: dll))
        }
    }

    return Fixture(
        runtime: WineRuntime(version: "t", rootDirectory: root.appending(path: "Runtime")),
        bottle: Bottle(url: bottleDir, settings: BottleSettings(name: "T")),
        root: root, system32: system32, syswow64: syswow64
    )
}

private func contents(_ url: URL) -> String? {
    FileManager.default.contents(atPath: url.path(percentEncoded: false))
        .flatMap { String(data: $0, encoding: .utf8) }
}

struct GraphicsBackendDeployerTests {
    @Test func deploysDXMTWithBackups() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }

        try GraphicsBackendDeployer.apply(.dxmt, runtime: fx.runtime, bottle: fx.bottle)

        #expect(contents(fx.system32.appending(path: "d3d11.dll")) == "DXMT-x64-d3d11.dll")
        #expect(contents(fx.syswow64.appending(path: "d3d11.dll")) == "DXMT-x32-d3d11.dll")
        #expect(contents(fx.system32.appending(path: "winemetal.dll")) == "DXMT-x64-winemetal.dll")
        // Originals preserved.
        #expect(contents(fx.system32.appending(path: "d3d11.dll.synthehol-orig")) == "builtin-d3d11.dll")
    }

    @Test func switchingBackendsRestoresOriginalsFirst() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.root) }

        try GraphicsBackendDeployer.apply(.dxmt, runtime: fx.runtime, bottle: fx.bottle)
        try GraphicsBackendDeployer.apply(.dxvk, runtime: fx.runtime, bottle: fx.bottle)

        // DXVK ships no dxgi/winemetal — the builtin dxgi must be restored and
        // DXMT's winemetal removed... winemetal had no builtin, so restore just
        // leaves DXVK's files plus restored originals.
        #expect(contents(fx.system32.appending(path: "d3d11.dll")) == "DXVK-x64-d3d11.dll")
        #expect(contents(fx.system32.appending(path: "dxgi.dll")) == "builtin-dxgi.dll")
        #expect(contents(fx.system32.appending(path: "d3d10core.dll")) == "DXVK-x64-d3d10core.dll")

        // Reverting to a no-deploy backend restores everything replaced.
        try GraphicsBackendDeployer.apply(.d3dMetal, runtime: fx.runtime, bottle: fx.bottle)
        #expect(contents(fx.system32.appending(path: "d3d11.dll")) == "builtin-d3d11.dll")
        #expect(contents(fx.system32.appending(path: "dxgi.dll")) == "builtin-dxgi.dll")
    }

    @Test func overridesMatchDeployedDLLs() {
        #expect(GraphicsBackendDeployer.dllOverrides(for: .dxmt) == "d3d10core,d3d11,dxgi=n,b")
        #expect(GraphicsBackendDeployer.dllOverrides(for: .dxvk) == "d3d10core,d3d11=n,b")
        #expect(GraphicsBackendDeployer.dllOverrides(for: .d3dMetal) == nil)
    }

    @Test func environmentIncludesBackendOverrides() {
        var settings = BottleSettings(name: "Env")
        settings.graphicsBackend = .dxmt
        #expect(settings.wineEnvironment()["WINEDLLOVERRIDES"] == "d3d10core,d3d11,dxgi=n,b")
        settings.graphicsBackend = .dxvk
        settings.dxvkAsync = true
        let env = settings.wineEnvironment()
        #expect(env["WINEDLLOVERRIDES"] == "d3d10core,d3d11=n,b")
        #expect(env["DXVK_ASYNC"] == "1")
    }
}
