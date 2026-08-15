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

    /// Avoid CEF GPU, occlusion, and scaling switches: Wine 11.15's patched
    /// cross-process compositor needs Chromium's unmodified rendering path.
    public static let defaultLaunchArguments: [String] = []

    /// The Wine 11.15 GPTK beta has a known Chromium renderer wedge under
    /// MSYNC. Steam and games it starts use ESYNC until that runtime bug is
    /// fixed upstream. These values intentionally override the bottle's base
    /// synchronization environment.
    public static let compatibilityEnvironment = [
        "WINEMSYNC": "0",
        "WINEESYNC": "1"
    ]

    /// Environment overrides for debug launches. The base environment sets
    /// `WINEDEBUG=fixme-all`; this replaces it with Wine's default channels
    /// (err + fixme) plus timestamp/pid/tid prefixes on every line — so a
    /// freeze shows *when* and *where* output stopped — and seh (Windows
    /// exceptions) and loaddll (module loads). GST_DEBUG=3 surfaces GStreamer
    /// media errors, a common hang source in cutscenes/intro videos.
    public static let debugEnvironment: [String: String] = [
        "WINEDEBUG": "+timestamp,+pid,+tid,+seh,+loaddll",
        "GST_DEBUG": "3"
    ]

    /// A running Steam/game session: the monitor task (completes after the
    /// process exits and the bottle shuts down) and the session log file that
    /// captures all console output (Wine, Steam, and the game).
    public struct LaunchSession: Sendable {
        public let task: Task<Void, Never>
        public let logFileURL: URL?
    }

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
        extraEnvironment: [String: String] = [:],
        debugLogging: Bool = false,
        nudgeStuckLoadingFor nudgeGame: InstalledGame? = nil
    ) -> LaunchSession {
        let webHelperShim = SteamWebHelperShim()
        webHelperShim.prepareForLaunch(in: bottle)
        var environment = Self.compatibilityEnvironment
        environment.merge(extraEnvironment) { _, explicit in explicit }
        if debugLogging {
            environment.merge(Self.debugEnvironment) { _, debug in debug }
        }
        let steamExe = store.steamExecutable(in: bottle)
        let stream = executor.runProgram(
            at: steamExe, arguments: arguments, bottle: bottle, waitForExit: true,
            extraEnvironment: environment
        )
        let sessionLog = WineLogWriter(
            label: "steam \(bottle.settings.name)",
            header: [
                ("Bottle", bottle.url.path(percentEncoded: false)),
                ("Runtime", executor.runtime.version),
                ("Arguments", arguments.joined(separator: " "))
            ] + (debugLogging
                ? [("Debug", "WINEDEBUG=\(Self.debugEnvironment["WINEDEBUG"] ?? "")")]
                : [])
        )
        let nudger = nudgeGame.map { game in
            GameNudger.startMonitor(for: game) { [sessionLog] event in
                Log.steam.info("\(event, privacy: .public)")
                sessionLog?.append("[nudge] \(event)")
            }
        }
        Task.detached(priority: .utility) {
            // Steam repairs CEF immediately after startup. Let that complete,
            // then wrap the freshly installed helper and restart only CEF.
            // Repeat if a slower client update replaces it once more.
            for attempt in 0..<6 {
                try? await Task.sleep(for: .seconds(attempt == 0 ? 6 : 4))
                guard webHelperShim.deploy(in: bottle) else {
                    if webHelperShim.isDeployed(in: bottle) { return }
                    continue
                }
                _ = try? await executor.runWine(
                    ["taskkill", "/F", "/IM", "steamwebhelper.exe"], bottle: bottle,
                    extraEnvironment: environment
                )
                _ = try? await executor.runWine(
                    ["taskkill", "/F", "/IM", SteamWebHelperShim.valveFileName], bottle: bottle,
                    extraEnvironment: environment
                )
                Log.steam.info("Restarted Steam WebHelper with software rendering compatibility")
            }
        }
        let task = Task.detached(priority: .utility) {
            defer {
                nudger?.cancel()
                sessionLog?.close()
            }
            var networkHintGiven = false
            do {
                for try await event in stream {
                    switch event {
                    case .stdout(let text), .stderr(let text):
                        sessionLog?.append(text)
                        // "No internet" in Steam under Wine is almost always
                        // macOS-side (Whisky #787) — flag it once with the
                        // known causes so the log diagnoses itself.
                        if !networkHintGiven,
                           text.contains("Failed to resolve your host name") {
                            networkHintGiven = true
                            sessionLog?.append("""
                            [hint] Steam can't resolve the local hostname. Usual causes: \
                            macOS Local Network permission denied for Synthehol \
                            (System Settings > Privacy & Security > Local Network), \
                            IPv6 misbehaving (set the network service's IPv6 to Link-Local Only), \
                            or a firewall like Little Snitch blocking wine processes.
                            """)
                        }
                    case .launched(let pid):
                        sessionLog?.append("[launched pid \(pid)]")
                    case .terminated(let code):
                        sessionLog?.append("[exited \(code)]")
                    }
                }
            } catch {
                Log.steam.error("Steam launch stream failed: \(error, privacy: .public)")
                sessionLog?.append("[launch failed: \(error)]")
                return
            }
            // The waited-on process exited. Give a self-restarting bootstrapper
            // a grace window to reappear before declaring Steam closed.
            for _ in 0..<3 {
                try? await Task.sleep(for: .seconds(3))
                if await isRunning(in: bottle) {
                    while await isRunning(in: bottle) {
                        try? await Task.sleep(for: .seconds(5))
                    }
                    break
                }
            }
            Log.steam.info("Steam exited; shutting down bottle \(bottle.settings.name, privacy: .public)")
            try? await executor.killBottle(bottle)
        }
        return LaunchSession(task: task, logFileURL: sessionLog?.fileURL)
    }

    /// Launches an installed game via Steam (`steam.exe -applaunch <appid>`),
    /// so Steam handles DRM, cloud saves, and the overlay. Works whether or not
    /// the client is already running. Per-game settings supply extra launch
    /// arguments and environment variables.
    @discardableResult
    public func launchGame(
        _ game: InstalledGame,
        in bottle: Bottle,
        executor: WineExecutor,
        debugLogging: Bool = false
    ) -> LaunchSession {
        let settings = GameSettings.load(for: game, in: bottle)
        return launch(
            in: bottle,
            executor: executor,
            arguments: ["-applaunch", game.storeGameID] + settings.launchArgumentList,
            extraEnvironment: settings.environment,
            debugLogging: debugLogging,
            nudgeStuckLoadingFor: settings.nudgeStuckLoading ? game : nil
        )
    }

    /// Asks Steam to install an owned game (`steam://install/<appid>`): Steam
    /// shows its install dialog (drive/size/shortcuts) and downloads the game;
    /// the library picks it up via the steamapps watcher once installed.
    @discardableResult
    public func requestInstall(
        appID: String,
        in bottle: Bottle,
        executor: WineExecutor
    ) -> LaunchSession {
        launch(
            in: bottle,
            executor: executor,
            arguments: ["steam://install/\(appID)"]
        )
    }

    /// Asks Steam to uninstall a game (`steam://uninstall/<appid>`): Steam
    /// shows its own confirmation and removes the files/manifest itself —
    /// Synthehol never deletes game files behind Steam's back. The library
    /// updates via the steamapps watcher when the manifest disappears.
    @discardableResult
    public func requestUninstall(
        of game: InstalledGame,
        in bottle: Bottle,
        executor: WineExecutor
    ) -> LaunchSession {
        launch(
            in: bottle,
            executor: executor,
            arguments: ["steam://uninstall/\(game.storeGameID)"]
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

    /// Whether this bottle's Steam client is running. Wine processes report
    /// Windows-style argv (`C:\…\steam.exe`) with no bottle path, so pgrep
    /// alone can't pin a process to a bottle; instead, take pgrep's steam.exe
    /// candidates and check whether any holds files open under the bottle
    /// (the client always keeps its PE and prefix files open). Much cheaper
    /// than `wine tasklist`, which boots a whole Wine process per check
    /// (Whisky #917: app CPU churn while a game runs).
    public func isRunning(in bottle: Bottle) async -> Bool {
        // Wine's `start.exe /wait /unix …steam.exe` wrapper matches the
        // steam.exe pattern too and can outlive the client, so exclude it —
        // otherwise a dead session still reads as running.
        let candidates = Set(await Self.processIDs(matching: "steam\\.exe"))
            .subtracting(await Self.processIDs(matching: "start\\.exe"))
        guard !candidates.isEmpty else { return false }
        // lsof exits nonzero if any pid died between the calls but still
        // reports the rest, so don't gate on its exit code.
        let lsof = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/sbin/lsof"),
            arguments: ["-nP", "-Fn", "-p", candidates.sorted().joined(separator: ",")]
        )
        return lsof?.standardOutput.contains(bottle.url.canonicalPath) ?? false
    }

    private static func processIDs(matching pattern: String) async -> [String] {
        guard let result = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-f", pattern]
        ), result.exitCode == 0 else { return [] }
        return result.standardOutput.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Re-attaches to a Steam session that outlived the app (launched by a
    /// previous run, then the app quit — Whisky #680: orphaned clients never
    /// shut their bottle down). Waits for the client to exit, with the same
    /// self-update grace window as `launch`, then stops the bottle.
    public func adoptSession(in bottle: Bottle, executor: WineExecutor) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            while !Task.isCancelled {
                if await isRunning(in: bottle) {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                var restarted = false
                for _ in 0..<3 {
                    try? await Task.sleep(for: .seconds(3))
                    if await isRunning(in: bottle) { restarted = true; break }
                }
                if restarted { continue }
                Log.steam.info("Adopted Steam session ended; shutting down bottle \(bottle.settings.name, privacy: .public)")
                try? await executor.killBottle(bottle)
                return
            }
        }
    }
}
