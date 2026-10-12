import Foundation

/// Installs and repairs Synthehol's native Steam injection. This is derived
/// from NotProton's deployment design but is independently owned, named, and
/// packaged by Synthehol.
public enum NativeSteamInstaller {
    public static let environmentKey = "LSEnvironment"
    public static let insertKey = "DYLD_INSERT_LIBRARIES"
    public static let controllerBlockKey = "SDL_JOYSTICK_BLACKLIST_DEVICES"
    public static let controllerBlockValue = "0x05ac/0x0004"
    public static let backupName = "Steam.Info.plist.before-synthehol-steamplay"
    private static let legacyBackupName = "Info.plist.before-synthehol-steamplay"

    public struct DeploymentRecord: Codable, Sendable, Equatable {
        public let version: Int
        public let installedAt: Date
        public let steamBundle: String

        public init(version: Int = 1, installedAt: Date = .now, steamBundle: String) {
            self.version = version
            self.installedAt = installedAt
            self.steamBundle = steamBundle
        }
    }

    public static func install(
        payload: NativeSteamPayload,
        steamApplication: URL = URL(filePath: "/Applications/Steam.app"),
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam"),
        runtime: WineRuntime? = nil,
        bottles: [Bottle] = [],
        runnerProvisioner: @Sendable (WineRuntime, URL, URL) async throws -> Void = provisionCompatibilityRunner,
        sign: @Sendable (URL) async throws -> Void = adHocSign
    ) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: steamApplication.path(percentEncoded: false)) else {
            throw NativeSteamInstallError.steamMissing
        }
        let plist = steamApplication.appending(path: "Contents/Info.plist")
        let destination = steamApplication.appending(path: "Contents/MacOS/\(NativeSteamPayload.dylibName)")
        try assertSteamIsWritable(steamApplication)
        var info = try readPlist(plist)
        var environment = info[environmentKey] as? [String: Any] ?? [:]
        if let insert = environment[insertKey] as? String, !insert.isEmpty {
            let paths = insert.split(separator: ":").map(String.init)
            let expected = destination.path(percentEncoded: false)
            guard paths.allSatisfy({ $0 == expected }) else {
                throw NativeSteamInstallError.foreignInjection(insert)
            }
        }

        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: support.appending(path: "signatures/macos.arm64"),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: support.appending(path: "bridge"), withIntermediateDirectories: true
        )
        try replace(payload.overlayShim, at: support.appending(path: NativeSteamPayload.overlayShimName))
        try replace(payload.runScript, at: support.appending(path: "run"))
        for signature in payload.signatures {
            try replace(signature, at: support.appending(path: "signatures/macos.arm64")
                .appending(path: signature.lastPathComponent))
        }
        try stageBridge(payload.bridge, at: support.appending(path: "bridge"))
        try NativeSteamBridgeProvisioner.provision(
            from: bottles, into: support.appending(path: "bridge")
        )
        try await provisionCompatibilityTool(
            runtime: runtime ?? currentRuntime(), support: support,
            payloadRoot: payload.root, runnerProvisioner: runnerProvisioner
        )
        try replace(payload.dylib, at: destination)

        let backup = support.appending(path: backupName)
        let legacyBackup = plist.deletingLastPathComponent().appending(path: legacyBackupName)
        if !fm.fileExists(atPath: backup.path(percentEncoded: false)) {
            if fm.fileExists(atPath: legacyBackup.path(percentEncoded: false)) {
                try fm.copyItem(at: legacyBackup, to: backup)
            } else {
                try fm.copyItem(at: plist, to: backup)
            }
        }
        // A file whose name begins with Info.plist inside Contents is treated by
        // codesign as a malformed nested bundle. Older builds stored the backup
        // there, so migrate it out before signing Steam.
        try? fm.removeItem(at: legacyBackup)
        environment[insertKey] = destination.path(percentEncoded: false)
        environment[controllerBlockKey] = controllerBlockValue
        info[environmentKey] = environment
        try writePlist(info, to: plist)

        do {
            try await sign(destination)
            try await sign(steamApplication.appending(path: "Contents/MacOS/steam_osx"))
            try await sign(steamApplication)
        } catch {
            if let backupData = try? Data(contentsOf: backup) {
                try? backupData.write(to: plist, options: .atomic)
            }
            throw error
        }

        let record = DeploymentRecord(steamBundle: steamApplication.path(percentEncoded: false))
        let data = try JSONEncoder().encode(record)
        try data.write(to: support.appending(path: "deployment.json"), options: .atomic)
    }

    public static func repair(
        steamApplication: URL = URL(filePath: "/Applications/Steam.app"),
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam"),
        sign: @Sendable (URL) async throws -> Void = adHocSign
    ) async throws {
        let fm = FileManager.default
        let plist = steamApplication.appending(path: "Contents/Info.plist")
        let backup = support.appending(path: backupName)
        let legacyBackup = plist.deletingLastPathComponent().appending(path: legacyBackupName)
        if !fm.fileExists(atPath: backup.path(percentEncoded: false)),
           fm.fileExists(atPath: legacyBackup.path(percentEncoded: false)) {
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            try fm.copyItem(at: legacyBackup, to: backup)
        }
        guard fm.fileExists(atPath: backup.path(percentEncoded: false)) else {
            throw NativeSteamInstallError.backupMissing
        }
        let data = try Data(contentsOf: backup)
        try data.write(to: plist, options: .atomic)
        try? fm.removeItem(at: legacyBackup)
        try await sign(steamApplication.appending(path: "Contents/MacOS/steam_osx"))
        try await sign(steamApplication)
        try? fm.removeItem(at: support.appending(path: "deployment.json"))
    }

    private static func replace(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }

    /// The vendored bridge uses architecture-prefixed resource names, while the
    /// Steam Play launcher consumes Proton's directory layout.
    private static func stageBridge(_ components: [URL], at bridge: URL) throws {
        let destinations: [String: [String]] = [
            "steam.exe": ["steam.exe"],
            "x86_64-windows-lsteamclient.dll": [
                "lsteamclient.dll", "x86_64-windows/lsteamclient.dll",
            ],
            "x86_64-unix-lsteamclient.so": [
                "lsteamclient.so", "x86_64-unix/lsteamclient.so",
            ],
            "i386-windows-lsteamclient.dll": ["i386-windows/lsteamclient.dll"],
        ]
        for component in components {
            guard let paths = destinations[component.lastPathComponent] else { continue }
            for path in paths {
                try replace(component, at: bridge.appending(path: path))
            }
        }
    }

    /// Registers the active Synthehol Wine runtime as a local Steam Play tool.
    /// The injected client writes the VDF manifests from this tab-separated list
    /// before Steam scans compatibilitytools.d on its next launch.
    private static func provisionCompatibilityTool(
        runtime: WineRuntime?, support: URL, payloadRoot: URL,
        runnerProvisioner: @Sendable (WineRuntime, URL, URL) async throws -> Void
    ) async throws {
        guard let runtime, runtime.isValid else {
            throw NativeSteamInstallError.runtimeMissing
        }
        let fm = FileManager.default
        let safeVersion = runtime.version.map {
            $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "-"
        }
        let build = String(safeVersion)
        // Steam recognizes Proton-style Windows AutoCloud roots by the internal
        // tool name. Keep this marker even though the displayed name is Synthehol.
        // Without it, Mac Steam skips AppData/Documents saves as unresolved paths.
        let name = "synthehol-proton-\(build)"
        let runner = support.appending(path: "runners/crossover-\(build)")
        try await runnerProvisioner(runtime, support, payloadRoot)
        guard fm.fileExists(atPath: runner.appending(path: "CrossOver/lib/wine").path) else {
            throw NativeSteamInstallError.runnerInstallationFailed("The cloned runtime is incomplete.")
        }
        let tools = "\(name)\t\(build)\trosetta\tSynthehol Steam Play (\(runtime.version))\n"
        try Data(tools.utf8).write(to: support.appending(path: "tools"), options: .atomic)
    }

    public static func provisionCompatibilityRunner(
        runtime: WineRuntime, support: URL, payloadRoot: URL
    ) async throws {
        let fm = FileManager.default
        let runner = support.appending(path: "runners/crossover-\(runtime.version)")
        let staging = runner.deletingLastPathComponent()
            .appending(path: ".\(runner.lastPathComponent).new")
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let clone = staging.appending(path: "CrossOver")
        let source = runtime.librariesDirectory.appending(path: "Wine")
        let copied = try await ProcessRunner.run(
            executable: URL(filePath: "/bin/cp"),
            arguments: ["-c", "-R", source.path(percentEncoded: false), clone.path(percentEncoded: false)]
        )
        guard copied.exitCode == 0 else {
            try? fm.removeItem(at: staging)
            throw NativeSteamInstallError.runnerInstallationFailed(copied.standardError)
        }

        let bridge = support.appending(path: "bridge")
        do {
            try NativeSteamNtdllPatcher.install(
                runtime: runtime, clone: clone, bridge: bridge, payloadRoot: payloadRoot
            )
            for (arch, name) in [
                ("x86_64-windows", "lsteamclient.dll"),
                ("i386-windows", "lsteamclient.dll"),
                ("x86_64-unix", "lsteamclient.so"),
            ] {
                let source = bridge.appending(path: "\(arch)/\(name)")
                guard fm.fileExists(atPath: source.path) else { continue }
                try replace(source, at: clone.appending(path: "lib/wine/\(arch)/\(name)"))
            }
            if D3DMetalSupport.isImported {
                let metalClone = staging.appending(path: "D3DMetal")
                let copied = try await ProcessRunner.run(
                    executable: URL(filePath: "/bin/cp"),
                    arguments: ["-c", "-R", clone.path, metalClone.path]
                )
                guard copied.exitCode == 0 else {
                    throw NativeSteamInstallError.runnerInstallationFailed(copied.standardError)
                }
                try stageD3DMetalModules(in: metalClone, from: D3DMetalSupport.windowsLibraries)
            }
            if fm.fileExists(atPath: runner.path) { try fm.removeItem(at: runner) }
            try fm.moveItem(at: staging, to: runner)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Install Apple's paired modules into a separate D3DMetal runner copy.
    /// The normal runner's DXGI remains available to other backends.
    static func stageD3DMetalModules(in clone: URL, from sourceDirectory: URL) throws {
        let fm = FileManager.default
        let modules = clone.appending(path: "lib/wine")
        let windows = modules.appending(path: "x86_64-windows")
        let unix = modules.appending(path: "x86_64-unix")
        try fm.createDirectory(at: windows, withIntermediateDirectories: true)
        try fm.createDirectory(at: unix, withIntermediateDirectories: true)
        for name in ["dxgi", "d3d10", "d3d10core", "d3d11", "d3d12"] {
            let source = sourceDirectory.appending(path: "\(name).dll")
            guard fm.fileExists(atPath: source.path) else { continue }
            try replace(source, at: windows.appending(path: "\(name).dll"))
            let link = unix.appending(path: "\(name).so")
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(
                atPath: link.path, withDestinationPath: "../../external/libd3dshared.dylib"
            )
        }
    }

    private static func currentRuntime() -> WineRuntime? {
        let link = SyntheholPaths.runtimes.appending(path: "current")
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: link.path(percentEncoded: false)
        ) else { return nil }
        let root = destination.hasPrefix("/")
            ? URL(filePath: destination)
            : SyntheholPaths.runtimes.appending(path: destination)
        let runtime = WineRuntime(version: root.lastPathComponent, rootDirectory: root)
        return runtime.isValid ? runtime : nil
    }

    private static func assertSteamIsWritable(_ application: URL) throws {
        let directory = application.appending(path: "Contents/MacOS")
        let probe = directory.appending(path: ".synthehol-write-probe")
        do {
            try Data("probe".utf8).write(to: probe)
            try FileManager.default.removeItem(at: probe)
        } catch let error as NSError where error.code == NSFileWriteNoPermissionError {
            throw NativeSteamInstallError.appManagementPermissionRequired
        } catch {
            throw error
        }
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { throw NativeSteamInstallError.invalidPlist }
        return value
    }

    private static func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value, format: .xml, options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    public static func adHocSign(_ url: URL) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/codesign"),
            arguments: ["--force", "--sign", "-", url.path(percentEncoded: false)]
        )
        guard result.exitCode == 0 else {
            throw NativeSteamInstallError.signingFailed(result.standardError)
        }
    }
}

public enum NativeSteamInstallError: Error, LocalizedError {
    case steamMissing
    case appManagementPermissionRequired
    case runtimeMissing
    case invalidPlist
    case foreignInjection(String)
    case backupMissing
    case signingFailed(String)
    case unsupportedRuntime(String)
    case runtimeComponentMismatch(String)
    case payloadVerificationFailed(String)
    case runnerInstallationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .steamMissing: "The macOS Steam application is not installed."
        case .appManagementPermissionRequired:
            "Synthehol needs permission to update Steam. Allow Synthehol in System Settings → Privacy & Security → App Management, then try again."
        case .runtimeMissing:
            "Install a Synthehol Wine runtime before enabling Steam Play."
        case .invalidPlist: "Steam's Info.plist could not be read."
        case .foreignInjection(let value): "Steam already contains another injection: \(value)"
        case .backupMissing: "Synthehol's original Steam configuration backup is missing."
        case .signingFailed(let detail): "Steam could not be signed. \(detail)"
        case .unsupportedRuntime(let version):
            "Wine runtime \(version) does not have a verified Steam IPC patch. Install the supported GPTK runtime and try again."
        case .runtimeComponentMismatch(let component):
            "The installed Wine runtime does not match the verified \(component) build. Reinstall the runtime and try again."
        case .payloadVerificationFailed(let component):
            "The Steam IPC patch failed verification for \(component). Nothing was installed."
        case .runnerInstallationFailed(let detail):
            "The Steam Play runtime could not be cloned. \(detail)"
        }
    }
}
