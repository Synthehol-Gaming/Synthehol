import Foundation

/// Availability and import handling for D3DMetal (Apple's Game Porting
/// Toolkit translation layer, Direct3D 9–12 → Metal).
///
/// D3DMetal is never redistributed with Synthehol (Apple's GPTK license):
/// the user downloads the Game Porting Toolkit from Apple and imports it;
/// the libraries are copied under our Application Support. Running it also
/// needs a CrossOver-lineage runtime (the 4.x beta built from winecx-gptk) —
/// stock Wine can't load the D3DMetal framework.
public enum D3DMetalSupport {
    /// The current GPTK pre-release requires this macOS or newer.
    public static let minimumOS = OperatingSystemVersion(
        majorVersion: 26, minorVersion: 0, patchVersion: 0
    )

    public static var osSupported: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(minimumOS)
    }

    /// Where the user's imported GPTK content lives. Mutable for tests only.
    nonisolated(unsafe) static var importDirectory: URL = SyntheholPaths.gptk

    /// GPTK's Windows-side shim DLLs (d3d9…d3d12, dxgi), deployed into a
    /// bottle's system32 like any other backend.
    public static var windowsLibraries: URL {
        importDirectory.appending(path: "lib/wine/x86_64-windows")
    }

    /// GPTK's Mac-side pieces (D3DMetal.framework, libd3dshared.dylib),
    /// installed into the runtime's `lib/external/` where CrossOver-lineage
    /// Wine loads them.
    public static var externalLibraries: URL {
        importDirectory.appending(path: "lib/external")
    }

    public static var isImported: Bool {
        let fm = FileManager.default
        return fm.fileExists(
            atPath: externalLibraries.appending(path: "libd3dshared.dylib")
                .path(percentEncoded: false)
        ) && fm.fileExists(
            atPath: windowsLibraries.appending(path: "d3d11.dll")
                .path(percentEncoded: false)
        )
    }

    /// Whether a runtime can host D3DMetal. Only the CrossOver-lineage 4.x
    /// builds (winecx-gptk) can; the 3.x series is stock Wine.
    public static func runtimeSupports(_ runtime: WineRuntime) -> Bool {
        (runtime.version.split(separator: ".").first.flatMap { Int($0) } ?? 0) >= 4
    }

    /// A mounted volume containing the toolkit: the inner "Evaluation
    /// environment" image when already attached, else the outer GPTK volume.
    public static func mountedGPTKVolume() -> URL? {
        let volumes = (try? FileManager.default.contentsOfDirectory(
            at: URL(filePath: "/Volumes"), includingPropertiesForKeys: nil
        )) ?? []
        return volumes.first {
            $0.lastPathComponent.localizedCaseInsensitiveContains("Evaluation environment")
        } ?? volumes.first {
            $0.lastPathComponent.localizedCaseInsensitiveContains("Game Porting Toolkit")
        }
    }

    public enum ImportError: LocalizedError {
        case librariesNotFound(URL)
        case mountFailed(String)

        public var errorDescription: String? {
            switch self {
            case .librariesNotFound(let url):
                "Couldn't find the Game Porting Toolkit libraries in \"\(url.lastPathComponent)\". Pick the mounted Game Porting Toolkit disk image (or its \"redist\" folder) from Apple's download."
            case .mountFailed(let name):
                "Couldn't open the nested disk image \"\(name)\" inside the Game Porting Toolkit download."
            }
        }
    }

    /// Imports GPTK by copying its `lib/` tree into our storage. Accepts the
    /// mounted volume root, the `redist` folder, or `lib` itself — and when
    /// given Apple's *outer* GPTK volume (docs and tools only), transparently
    /// mounts the nested "Evaluation environment …" disk image that actually
    /// carries the libraries, imports from it, and detaches it again.
    public static func importGPTK(from root: URL) async throws {
        if let lib = directLibraries(under: root) {
            try copyLibraries(from: lib)
            return
        }
        let fm = FileManager.default
        let dmgs = ((try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? [])
            .filter { $0.pathExtension.lowercased() == "dmg" }
            .sorted { first, _ in
                first.lastPathComponent.localizedCaseInsensitiveContains("Evaluation")
            }
        for dmg in dmgs {
            guard let mountPoint = try? await mount(dmg) else { continue }
            let lib = directLibraries(under: mountPoint)
            do {
                if let lib { try copyLibraries(from: lib) }
                await detach(mountPoint)
            } catch {
                await detach(mountPoint)
                throw error
            }
            if lib != nil { return }
        }
        throw ImportError.librariesNotFound(root)
    }

    private static func directLibraries(under root: URL) -> URL? {
        let candidates = [
            root.appending(path: "redist/lib"),
            root.appending(path: "lib"),
            root
        ]
        return candidates.first { candidate in
            FileManager.default.fileExists(
                atPath: candidate.appending(path: "external/libd3dshared.dylib")
                    .path(percentEncoded: false)
            )
        }
    }

    private static func copyLibraries(from lib: URL) throws {
        let fm = FileManager.default
        let destination = importDirectory.appending(path: "lib")
        try fm.createDirectory(
            at: importDirectory, withIntermediateDirectories: true
        )
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: lib, to: destination)
        stripQuarantine(destination)
    }

    /// Apple's DMG download stamps `com.apple.quarantine` on everything;
    /// Gatekeeper then blocks `dlopen` of the libraries and D3DMetal fails
    /// device creation (E_FAIL) with no other symptom. Strip it recursively.
    static func stripQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path(percentEncoded: false)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func mount(_ dmg: URL) async throws -> URL {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/hdiutil"),
            arguments: [
                "attach", "-nobrowse", "-readonly", "-plist",
                dmg.path(percentEncoded: false)
            ]
        )
        guard result.exitCode == 0,
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(result.standardOutput.utf8), format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mountPoint = entities.compactMap({ $0["mount-point"] as? String }).first
        else {
            throw ImportError.mountFailed(dmg.lastPathComponent)
        }
        return URL(filePath: mountPoint)
    }

    private static func detach(_ mountPoint: URL) async {
        _ = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/hdiutil"),
            arguments: ["detach", mountPoint.path(percentEncoded: false)]
        )
    }
}
