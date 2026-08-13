import Foundation

/// Deploys a graphics backend's DLLs (DXMT or DXVK, shipped with the runtime)
/// into a bottle's prefix.
///
/// Originals are renamed to `<name>.dll.synthehol-orig` before being replaced,
/// and switching backends restores them first — never destructive (Whisky
/// deleted originals with no backup, permanently breaking prefixes).
public enum GraphicsBackendDeployer {
    static let backupSuffix = "synthehol-orig"

    /// Applies a backend to the bottle's prefix: restores any previously
    /// replaced DLLs, then copies the new backend's DLLs in (x64 → system32,
    /// x32 → syswow64).
    public static func apply(
        _ backend: GraphicsBackend, runtime: WineRuntime, bottle: Bottle
    ) throws {
        try restoreOriginals(in: bottle)

        let sourceRoot: URL
        switch backend {
        case .dxmt:
            sourceRoot = runtime.librariesDirectory.appending(path: "DXMT")
        case .dxvk:
            sourceRoot = runtime.dxvkDirectory
        case .d3dMetal:
            // Requires the user's GPTK import (Phase 6); until then the prefix
            // keeps Wine's builtin D3D.
            return
        }
        try deploy(
            from: sourceRoot.appending(path: "x64"),
            into: bottle.driveC.appending(path: "windows/system32")
        )
        try deploy(
            from: sourceRoot.appending(path: "x32"),
            into: bottle.driveC.appending(path: "windows/syswow64")
        )
    }

    /// DLL override string for the deployed backend, merged into the Wine
    /// environment so the native DLLs in the prefix win over builtins.
    public static func dllOverrides(for backend: GraphicsBackend) -> String? {
        switch backend {
        case .dxmt: "d3d10core,d3d11,dxgi=n,b"
        case .dxvk: "d3d10core,d3d11=n,b"
        case .d3dMetal: nil
        }
    }

    static func deploy(from source: URL, into target: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path(percentEncoded: false)),
              fm.fileExists(atPath: target.path(percentEncoded: false))
        else { return }
        for dll in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        where dll.pathExtension.lowercased() == "dll" {
            let destination = target.appending(path: dll.lastPathComponent)
            let backup = destination.appendingPathExtension(backupSuffix)
            let destinationPath = destination.path(percentEncoded: false)
            if fm.fileExists(atPath: destinationPath),
               !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                try fm.moveItem(at: destination, to: backup)
            }
            if fm.fileExists(atPath: destinationPath) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: dll, to: destination)
        }
    }

    /// Puts back every DLL we replaced (idempotent).
    public static func restoreOriginals(in bottle: Bottle) throws {
        let fm = FileManager.default
        for dir in ["windows/system32", "windows/syswow64"] {
            let target = bottle.driveC.appending(path: dir)
            guard let entries = try? fm.contentsOfDirectory(
                at: target, includingPropertiesForKeys: nil
            ) else { continue }
            for backup in entries where backup.pathExtension == backupSuffix {
                let original = backup.deletingPathExtension()
                try? fm.removeItem(at: original)
                try fm.moveItem(at: backup, to: original)
            }
        }
    }
}
