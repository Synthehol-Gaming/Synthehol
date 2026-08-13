import Foundation

/// Installs and launches the Windows Steam client in a bottle.
///
/// The Steam client itself is the sign-in and game-install experience —
/// Synthehol never touches credentials; it bootstraps the client and then
/// reads `steamapps/` state from the outside (`SteamStore`).
public struct SteamInstaller: Sendable {
    public enum Progress: Sendable, Equatable {
        case downloading(bytesDownloaded: Int64, totalBytes: Int64?)
        case installing
        case verifying
    }

    public enum InstallError: Error, Equatable {
        case installerFailed(exitCode: Int32)
        case steamNotFoundAfterInstall
    }

    /// Valve's official installer. Not checksum-pinned — Valve replaces it in
    /// place — so the hash is recorded at download time for the log instead.
    public static let installerURL =
        URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    /// Launch arguments for running Steam under Wine. Empty by default on the
    /// current runtime; kept as a named profile so it can gain flags (or become
    /// remotely updatable) when Steam client updates break Wine again.
    public static let defaultLaunchArguments: [String] = []

    private let store = SteamStore()

    public init() {}

    /// Downloads SteamSetup.exe and runs the NSIS installer silently (`/S`).
    /// Returns the bottle with `steamInstalled` set and saved.
    @discardableResult
    public func install(
        in bottle: Bottle,
        executor: WineExecutor,
        onProgress: (@Sendable (Progress) -> Void)? = nil
    ) async throws -> Bottle {
        let cacheDir = SyntheholPaths.applicationSupport.appending(path: "Cache")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let installer = cacheDir.appending(path: "SteamSetup.exe")

        let sha256 = try await FileDownloader.download(
            Self.installerURL, to: installer
        ) { bytesDownloaded, totalBytes in
            onProgress?(.downloading(bytesDownloaded: bytesDownloaded, totalBytes: totalBytes))
        }
        Log.steam.info("Downloaded SteamSetup.exe (sha256 \(sha256, privacy: .public))")

        onProgress?(.installing)
        let result = try await executor.runWine(
            [installer.path(percentEncoded: false), "/S"],
            bottle: bottle
        )
        onProgress?(.verifying)
        guard store.isInstalled(in: bottle) else {
            if result.exitCode != 0 {
                throw InstallError.installerFailed(exitCode: result.exitCode)
            }
            throw InstallError.steamNotFoundAfterInstall
        }

        var updated = bottle
        updated.settings.steamInstalled = true
        try updated.saveSettings()
        return updated
    }

    /// Launches the Steam client. The user signs in and installs games through
    /// Steam's own UI. When the client exits, the bottle is shut down
    /// (`wineserver -k`) so no Wine service processes linger in the Dock —
    /// with a restart check, because Steam's bootstrapper relaunches itself
    /// during self-updates and must not be killed mid-update.
    @discardableResult
    public func launch(
        in bottle: Bottle,
        executor: WineExecutor,
        arguments: [String] = SteamInstaller.defaultLaunchArguments,
        extraEnvironment: [String: String] = [:]
    ) -> Task<Void, Never> {
        let steamExe = store.steamExecutable(in: bottle)
        let stream = executor.runProgram(
            at: steamExe, arguments: arguments, bottle: bottle, waitForExit: true,
            extraEnvironment: extraEnvironment
        )
        return Task.detached(priority: .utility) {
            do { for try await _ in stream {} } catch {
                Log.steam.error("Steam launch stream failed: \(error, privacy: .public)")
                return
            }
            // The waited-on process exited. Give a self-restarting bootstrapper
            // a grace window to reappear before declaring Steam closed.
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(3))
                if await executor.isProcessRunning(imageName: "steam.exe", bottle: bottle) {
                    while await executor.isProcessRunning(imageName: "steam.exe", bottle: bottle) {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    break
                }
            }
            Log.steam.info("Steam exited; shutting down bottle \(bottle.settings.name, privacy: .public)")
            try? await executor.killBottle(bottle)
        }
    }

    /// Launches an installed game via Steam (`steam.exe -applaunch <appid>`),
    /// so Steam handles DRM, cloud saves, and the overlay. Works whether or not
    /// the client is already running. Per-game settings supply extra launch
    /// arguments and environment variables.
    @discardableResult
    public func launchGame(
        _ game: InstalledGame,
        in bottle: Bottle,
        executor: WineExecutor
    ) -> Task<Void, Never> {
        let settings = GameSettings.load(for: game, in: bottle)
        return launch(
            in: bottle,
            executor: executor,
            arguments: ["-applaunch", game.storeGameID] + settings.launchArgumentList,
            extraEnvironment: settings.environment
        )
    }

    /// Asks a running Steam client to exit cleanly (`steam.exe -shutdown` —
    /// the same as Steam → Exit). Note: the window's close button does NOT
    /// exit Steam; it minimizes to a system tray that is invisible under
    /// Wine, so this is the reliable way to actually quit.
    public func requestExit(in bottle: Bottle, executor: WineExecutor) async {
        _ = try? await executor.runWine(
            [store.steamExecutable(in: bottle).path(percentEncoded: false), "-shutdown"],
            bottle: bottle
        )
    }

    /// Whether a Steam client process appears to be running for this bottle
    /// (best-effort: matches wine processes whose command line mentions the
    /// bottle's steam.exe).
    public func isRunning(in bottle: Bottle) async -> Bool {
        let result = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-if", "steam.exe"]
        )
        guard let result, result.exitCode == 0 else { return false }
        return !result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
