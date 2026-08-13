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

    /// Launches the Steam client (fire-and-forget). The user signs in and
    /// installs games through Steam's own UI.
    public func launch(
        in bottle: Bottle,
        executor: WineExecutor,
        arguments: [String] = SteamInstaller.defaultLaunchArguments
    ) {
        let steamExe = store.steamExecutable(in: bottle)
        let stream = executor.runProgram(at: steamExe, arguments: arguments, bottle: bottle)
        Task.detached(priority: .utility) {
            for try await _ in stream {}
        }
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
