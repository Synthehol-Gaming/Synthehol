import Foundation

/// Deploys a graphics backend's DLLs (DXMT or DXVK, shipped with the runtime)
/// into a bottle's prefix.
///
/// Originals are renamed to `<name>.dll.synthehol-orig` before being replaced,
/// and switching backends restores them first — never destructive (Whisky
/// deleted originals with no backup, permanently breaking prefixes).
public enum GraphicsBackendDeployer {
    static let backupSuffix = "synthehol-orig"
    static let d3dMetalDeploymentMarker = ".synthehol-d3dmetal-v3"

    /// Applies a backend to the bottle's prefix: restores any previously
    /// replaced DLLs, then copies the new backend's DLLs in (x64 → system32,
    /// x32 → syswow64).
    public enum DeployError: LocalizedError {
        case gptkNotImported
        case runtimeNotGPTKCapable(String)

        public var errorDescription: String? {
            switch self {
            case .gptkNotImported:
                "D3DMetal needs Apple's Game Porting Toolkit imported first (Settings → Graphics → Import Game Porting Toolkit)."
            case .runtimeNotGPTKCapable(let version):
                "D3DMetal needs the GPTK-capable beta runtime; the current runtime (\(version)) can't host it."
            }
        }
    }

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
            guard D3DMetalSupport.isImported else { throw DeployError.gptkNotImported }
            guard D3DMetalSupport.runtimeSupports(runtime) else {
                throw DeployError.runtimeNotGPTKCapable(runtime.version)
            }
            // D3DMetal has paired Wine builtin modules: PE entry points in
            // x86_64-windows and Mach-O entry points in x86_64-unix. Apple's
            // PE files are *not* native Windows DLLs and copying them into a
            // prefix cannot override Wine's builtin modules. Both halves must
            // be installed into the runtime's module directories.
            try installExternalLibraries(into: runtime)
            try deploy(
                from: D3DMetalSupport.windowsLibraries,
                into: runtime.librariesDirectory.appending(
                    path: "Wine/lib/wine/x86_64-windows"
                )
            )
            try ensureCrossOverUserSymlink(in: bottle)
            try scopeSteamToDXVK(runtime: runtime, bottle: bottle)
            try Data().write(
                to: bottle.url.appending(path: d3dMetalDeploymentMarker),
                options: .atomic
            )
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
        // Apple's bridge is installed as Wine's builtin implementation.
        // Steam is separately scoped to app-local DXVK DLLs via AppDefaults.
        case .d3dMetal: nil
        }
    }

    /// Detects bottles made by the earlier, incomplete D3DMetal deployment.
    /// A correctly deployed bridge has both Apple's d3d11.dll and the saved
    /// Wine builtin beside it. This lets app upgrades repair existing bottles
    /// without rewriting every backend on every launch.
    public static func d3dMetalNeedsRepair(in bottle: Bottle) -> Bool {
        !FileManager.default.fileExists(
            atPath: bottle.url.appending(path: d3dMetalDeploymentMarker)
                .path(percentEncoded: false)
        )
    }

    /// Copies the imported GPTK Mac-side libraries (D3DMetal.framework,
    /// libd3dshared.dylib) into the runtime's `Wine/lib/external/`, then
    /// points the unix-side D3D entry points at them: per the runtime's own
    /// external/README, `x86_64-unix/{d3d10,d3d11,d3d12,dxgi}.so` must be
    /// *symlinks* to `../../external/libd3dshared.dylib` — a copy would move
    /// `@loader_path` and D3DMetal dies on an assertion with no Wine error.
    static func installExternalLibraries(into runtime: WineRuntime) throws {
        let fm = FileManager.default
        let target = runtime.librariesDirectory.appending(path: "Wine/lib/external")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(
            at: D3DMetalSupport.externalLibraries, includingPropertiesForKeys: nil
        ) where item.lastPathComponent != "README" {
            let destination = target.appending(path: item.lastPathComponent)
            if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: item, to: destination)
        }
        // Belt and braces: a quarantined dylib is un-dlopen-able (silent
        // E_FAIL) even if the import-time strip was skipped.
        D3DMetalSupport.stripQuarantine(target)

        let unixDir = runtime.librariesDirectory.appending(path: "Wine/lib/wine/x86_64-unix")
        try fm.createDirectory(at: unixDir, withIntermediateDirectories: true)
        for so in ["d3d10.so", "d3d11.so", "d3d12.so", "dxgi.so"] {
            let link = unixDir.appending(path: so)
            let linkPath = link.path(percentEncoded: false)
            // Keep the runtime's original builtin around, then symlink.
            let backup = link.appendingPathExtension(backupSuffix)
            if fm.fileExists(atPath: linkPath),
               (try? fm.destinationOfSymbolicLink(atPath: linkPath)) == nil,
               !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
                try fm.moveItem(at: link, to: backup)
            }
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(
                atPath: linkPath,
                withDestinationPath: "../../external/libd3dshared.dylib"
            )
        }
    }

    /// Steam's own UI cannot render through the GPTK shims or this runtime's
    /// builtin wined3d (both black-screen); per the runtime's release notes,
    /// Steam works in a D3DMetal bottle "when Steam's executables are scoped
    /// to DXVK". Windows loads app-local DLLs before system32, so DXVK
    /// copies in Steam's directories win for the client while games still
    /// get the GPTK shims from system32.
    static func scopeSteamToDXVK(runtime: WineRuntime, bottle: Bottle) throws {
        let steamDir = SteamStore().steamDirectory(in: bottle)
        // steam.exe is 32-bit; steamwebhelper.exe (the renderer) is 64-bit.
        try deploy(from: runtime.dxvkDirectory.appending(path: "x32"), into: steamDir)
        try deploy(
            from: runtime.dxvkDirectory.appending(path: "x64"),
            into: steamDir.appending(path: "bin/cef/cef.win64")
        )
    }

    /// CrossOver-lineage runtimes look for the Windows user profile under
    /// `users/crossover`; stock prefixes use `users/<name>`. A symlink keeps
    /// one prefix working under both.
    static func ensureCrossOverUserSymlink(in bottle: Bottle) throws {
        let fm = FileManager.default
        let usersDir = bottle.driveC.appending(path: "users")
        let linkPath = usersDir.appending(path: "crossover").path(percentEncoded: false)
        // fileExists follows symlinks, so also probe for a dangling link.
        guard !fm.fileExists(atPath: linkPath),
              (try? fm.destinationOfSymbolicLink(atPath: linkPath)) == nil
        else { return }
        let profiles = (try? fm.contentsOfDirectory(
            at: usersDir, includingPropertiesForKeys: nil
        )) ?? []
        guard let profile = profiles.first(where: {
            $0.lastPathComponent != "Public" && $0.hasDirectoryPath
        }) else { return }
        // Relative target so the bottle stays relocatable.
        try fm.createSymbolicLink(
            atPath: linkPath, withDestinationPath: profile.lastPathComponent
        )
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

    static let managedDirectories = [
        "windows/system32", "windows/syswow64",
        "Program Files (x86)/Steam",
        "Program Files (x86)/Steam/bin/cef/cef.win64"
    ]

    /// Discards deployed DLLs *and* their backups so the next `wineboot -u`
    /// regenerates fresh builtins. Used across runtime upgrades, where
    /// restoring a backup would resurrect the previous runtime's DLLs.
    public static func resetToBuiltins(in bottle: Bottle) throws {
        let fm = FileManager.default
        for dir in managedDirectories {
            let target = bottle.driveC.appending(path: dir)
            guard let entries = try? fm.contentsOfDirectory(
                at: target, includingPropertiesForKeys: nil
            ) else { continue }
            for backup in entries where backup.pathExtension == backupSuffix {
                try? fm.removeItem(at: backup.deletingPathExtension())
                try? fm.removeItem(at: backup)
            }
        }
    }

    /// Puts back every DLL we replaced (idempotent). Covers the Steam
    /// directories too, where the D3DMetal backend scopes the client to DXVK.
    public static func restoreOriginals(in bottle: Bottle) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: bottle.url.appending(path: d3dMetalDeploymentMarker))
        for dir in managedDirectories {
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
