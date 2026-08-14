import AppKit
import Darwin
import Foundation
import Observation
import os
import SyntheholKit

private let gameStateLog = Logger(
    subsystem: "com.colinobrien.Synthehol", category: "game-state"
)

/// App-wide observable state: the runtime, the bottle list, and operations on
/// them. All mutations funnel through here; SyntheholKit stays UI-free.
@MainActor
@Observable
final class AppModel {
    let bottleStore = BottleStore()
    let runtimeStore = RuntimeStore()

    var bottles: [Bottle] = []
    var selectedBottleID: Bottle.ID?
    var runtime: WineRuntime?
    var runtimeProgress: RuntimeInstallProgress?
    var busyBottleIDs: Set<Bottle.ID> = []
    var steamProgress: [Bottle.ID: SteamInstaller.Progress] = [:]
    var installedGames: [Bottle.ID: [InstalledGame]] = [:]
    var steamRunning: Set<Bottle.ID> = []
    /// Visibility of Steam's own Wine process. Game windows use separate
    /// processes and remain visible when the client is hidden.
    var steamClientVisible: Set<Bottle.ID> = []
    private var steamClientPIDs: [Bottle.ID: pid_t] = [:]
    private var steamClientRequestedVisible: Set<Bottle.ID> = []

    private func persistedSteamClientPID(for bottle: Bottle) -> pid_t? {
        let value = UserDefaults.standard.integer(
            forKey: "steamClientPID.\(bottle.id)"
        )
        return value > 0 ? pid_t(value) : nil
    }

    private func rememberSteamClientPID(_ pid: pid_t, for bottle: Bottle) {
        steamClientPIDs[bottle.id] = pid
        UserDefaults.standard.set(
            Int(pid), forKey: "steamClientPID.\(bottle.id)"
        )
    }

    private func forgetSteamClientPID(for bottle: Bottle) {
        steamClientPIDs.removeValue(forKey: bottle.id)
        UserDefaults.standard.removeObject(
            forKey: "steamClientPID.\(bottle.id)"
        )
    }
    var ownedGames: [Bottle.ID: [InstalledGame]] = [:]
    var ownedGamesError: [Bottle.ID: String] = [:]
    var loadingOwnedGames: Set<Bottle.ID> = []
    var lastError: String?

    /// Per-game launch lifecycle, keyed by game ID. `starting` from the Play
    /// click until the game's process appears; `running` while it exists.
    /// Absent = not running (including after a crash — the watcher clears it
    /// when the process disappears, however it went).
    enum GameRunState: Equatable { case starting, running }
    var gameRunStates: [String: GameRunState] = [:]
    private var gameWatchers: [String: Task<Void, Never>] = [:]

    /// Sidebar library filter. Genres come from cached store metadata.
    enum GameFilter: Hashable { case all, genre(String) }
    var selectedGameFilter: GameFilter = .all
    /// Store metadata per game ID, loaded lazily as libraries refresh.
    var gameMetadata: [String: SteamAppMetadata] = [:]
    private let metadataStore = SteamMetadataStore()

    /// Genres present in the selected configuration's installed library,
    /// with counts, for the sidebar filter list.
    var sidebarGenres: [(genre: String, count: Int)] {
        guard let bottle = selectedBottle else { return [] }
        var counts: [String: Int] = [:]
        for game in installedGames[bottle.id] ?? [] {
            for genre in gameMetadata[game.id]?.genres ?? [] {
                counts[genre, default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private let artworkCache = ArtworkCache()
    /// Observable so tiles update the moment artwork changes.
    var posterImages: [String: NSImage] = [:]
    private var watchers: [Bottle.ID: DirectoryWatcher] = [:]

    var selectedBottle: Bottle? {
        bottles.first { $0.id == selectedBottleID }
    }

    var executor: WineExecutor? {
        runtime.map(WineExecutor.init)
    }

    // MARK: Lifecycle

    func refresh() async {
        runtime = await runtimeStore.current()
        bottles = await bottleStore.bottles()
        if selectedBottleID == nil { selectedBottleID = bottles.first?.id }
        WineLogWriter.deleteOldLogs()
        await repairIncompleteD3DMetalDeployments()
        await adoptRunningSessions()
    }

    /// Repairs bottles configured by builds that installed only D3DMetal's
    /// Mac-side payload. Those bottles silently selected wined3d/Vulkan for
    /// games and failed D3D11 initialization.
    private func repairIncompleteD3DMetalDeployments() async {
        guard let executor else { return }
        for bottle in bottles
        where bottle.settings.graphicsBackend == .d3dMetal
            && GraphicsBackendDeployer.d3dMetalNeedsRepair(in: bottle) {
            do {
                // Steam launched before the repair retains the old DLL load
                // policy and hands it to games through its existing process.
                // A one-time full bottle restart is required for the repaired
                // backend to become effective.
                try? await executor.killBottle(bottle)
                steamRunning.remove(bottle.id)
                try GraphicsBackendDeployer.apply(
                    .d3dMetal, runtime: executor.runtime, bottle: bottle
                )
                try await executor.applyRegistrySettings(for: bottle)
            } catch {
                lastError = "Couldn't repair D3DMetal for \"\(bottle.settings.name)\": \(error.localizedDescription)"
            }
        }
    }

    private var didCleanUpOrphans = false

    /// Re-attaches to Steam sessions that outlived a previous app run: restores
    /// the running indicator and a monitor that shuts the bottle down when the
    /// client exits. Without this, quitting the app orphans the session and
    /// wineserver lingers forever after Steam closes (Whisky #680).
    ///
    /// The opposite orphan flavor — Steam already exited but wineserver and
    /// Wine's start.exe waiters linger — is cleaned up once at startup only:
    /// later refreshes could otherwise kill Wine tools or CLI sessions the
    /// user opened while the app runs.
    private func adoptRunningSessions() async {
        guard let executor else { return }
        let steam = SteamInstaller()
        for bottle in bottles where bottle.settings.steamInstalled {
            guard !steamRunning.contains(bottle.id) else { continue }
            guard await steam.isRunning(in: bottle) else {
                if !didCleanUpOrphans, !busyBottleIDs.contains(bottle.id) {
                    try? await executor.killBottle(bottle)
                }
                continue
            }
            steamRunning.insert(bottle.id)
            hideSteamClientSoon(in: bottle)
            refreshGames(in: bottle)
            // Restore "Running" badges for games that survived the relaunch.
            for game in installedGames[bottle.id] ?? [] where gameRunStates[game.id] == nil {
                if await !GameNudger.processIDs(for: game).isEmpty {
                    gameRunStates[game.id] = .running
                    watchGame(game)
                }
            }
            let monitor = steam.adoptSession(in: bottle, executor: executor)
            Task { [weak self] in
                await monitor.value
                self?.steamRunning.remove(bottle.id)
                self?.refreshGames(in: bottle)
            }
        }
        didCleanUpOrphans = true
    }

    // MARK: Launcher URLs (synthehol://launch?bottle=…&store=…&game=…)

    func handleLaunchURL(_ url: URL) async {
        guard url.scheme == "synthehol", url.host() == "launch",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return }
        let params = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } }
        )
        guard let bottlePath = params["bottle"],
              let store = params["store"],
              let gameID = params["game"]
        else {
            lastError = "Invalid launcher link."
            return
        }
        await refresh()
        let canonical = URL(filePath: bottlePath).canonicalPath
        guard let bottle = bottles.first(where: {
            $0.url.canonicalPath == canonical
        }) else {
            lastError = "This launcher points to a configuration Synthehol no longer knows about."
            return
        }
        selectedBottleID = bottle.id
        refreshGames(in: bottle)
        guard let game = installedGames[bottle.id]?.first(where: {
            $0.store == store && $0.storeGameID == gameID
        }) else {
            lastError = "The game for this launcher is no longer installed in \"\(bottle.settings.name)\"."
            return
        }
        launchGame(game, in: bottle)
    }

    // MARK: Artwork management

    /// Applies user-chosen artwork (from a file or a downloaded candidate).
    func setCustomPoster(_ data: Data, for game: InstalledGame) async {
        guard let image = NSImage(data: data) else {
            lastError = "That file doesn't look like an image."
            return
        }
        do {
            try await artworkCache.setCustomPoster(data, forGameID: game.id)
            posterImages[game.id] = image
        } catch {
            lastError = "Couldn't save artwork: \(error.localizedDescription)"
        }
    }

    /// Clears custom/cached artwork and re-fetches the default poster.
    func resetPoster(for game: InstalledGame, in bottle: Bottle) async {
        await artworkCache.resetPoster(forGameID: game.id)
        posterImages.removeValue(forKey: game.id)
        _ = await poster(for: game, in: bottle)
    }

    /// Exports a `.app` launcher for a game with its poster as the icon.
    func exportLauncher(for game: InstalledGame, in bottle: Bottle) async {
        do {
            let appURL = try LauncherExporter.export(game: game, bottle: bottle)
            if let poster = await poster(for: game, in: bottle) {
                NSWorkspace.shared.setIcon(
                    poster, forFile: appURL.path(percentEncoded: false)
                )
            }
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } catch {
            lastError = "Couldn't create launcher: \(error.localizedDescription)"
        }
    }

    // MARK: Runtime

    func installRuntime(_ manifest: RuntimeManifest = .stableDefault) async {
        runtimeProgress = .downloading(bytesDownloaded: 0, totalBytes: nil)
        defer { runtimeProgress = nil }
        do {
            runtime = try await runtimeStore.install(manifest) { progress in
                Task { @MainActor [weak self] in self?.runtimeProgress = progress }
            }
            await redeployBackendsAfterRuntimeChange()
        } catch {
            lastError = "Runtime install failed: \(error.localizedDescription)"
        }
    }

    /// A new Wine version updates each prefix on first boot and overwrites
    /// deployed backend DLLs with fresh builtins (this silently broke the
    /// deployed backend after a runtime switch). Force the prefix update now,
    /// then put every bottle's backend DLLs back.
    private func redeployBackendsAfterRuntimeChange() async {
        guard let executor else { return }
        for bottle in bottles where bottle.prefixExists {
            busyBottleIDs.insert(bottle.id)
            defer { busyBottleIDs.remove(bottle.id) }
            // Backups belong to the previous runtime; discard them so
            // wineboot regenerates fresh builtins instead of a later
            // restore resurrecting outdated DLLs.
            try? GraphicsBackendDeployer.resetToBuiltins(in: bottle)
            _ = try? await executor.runWine(["wineboot", "-u"], bottle: bottle)
            do {
                try GraphicsBackendDeployer.apply(
                    bottle.settings.graphicsBackend, runtime: executor.runtime, bottle: bottle
                )
            } catch {
                // D3DMetal prerequisites may be missing mid-setup; the
                // settings form surfaces state, so stay quiet here.
                Log.steam.error("Backend redeploy failed for \(bottle.settings.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: D3DMetal (Game Porting Toolkit)

    var d3dMetalOSSupported: Bool { D3DMetalSupport.osSupported }
    var gptkImported = D3DMetalSupport.isImported
    var runtimeSupportsD3DMetal: Bool {
        runtime.map(D3DMetalSupport.runtimeSupports) ?? false
    }
    /// All prerequisites met: the backend picker's D3DMetal option unlocks.
    var d3dMetalReady: Bool {
        d3dMetalOSSupported && gptkImported && runtimeSupportsD3DMetal
    }

    /// Asks for the mounted GPTK volume (pre-selected when detected) and
    /// imports its libraries.
    func importGPTK() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the mounted Game Porting Toolkit disk image from Apple's download (or its \"redist\" folder)."
        panel.prompt = "Import"
        panel.directoryURL = D3DMetalSupport.mountedGPTKVolume()
            ?? URL(filePath: "/Volumes")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try await D3DMetalSupport.importGPTK(from: url)
            gptkImported = D3DMetalSupport.isImported
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Installs the GPTK-capable beta runtime (the stable runtime is kept
    /// for rollback by the runtime store).
    func installBetaRuntime() async {
        await installRuntime(.gptkBeta)
    }

    // MARK: Bottles

    func createBottle(name: String, windowsVersion: WindowsVersion) async {
        guard let executor else {
            lastError = "Install the runtime before creating a configuration."
            return
        }
        guard await Task.detached(operation: { Rosetta2.isInstalled }).value else {
            lastError = "Rosetta 2 is required to run Windows games. Install it in Terminal with: softwareupdate --install-rosetta"
            return
        }
        do {
            let bottle = try await bottleStore.create(name: name, windowsVersion: windowsVersion)
            bottles = await bottleStore.bottles()
            selectedBottleID = bottle.id
            busyBottleIDs.insert(bottle.id)
            defer { busyBottleIDs.remove(bottle.id) }
            try await executor.initializePrefix(for: bottle)
            try await executor.applyRegistrySettings(for: bottle)
            try GraphicsBackendDeployer.apply(
                bottle.settings.graphicsBackend, runtime: executor.runtime, bottle: bottle
            )
            await refresh()
        } catch {
            lastError = "Couldn't create configuration: \(error.localizedDescription)"
        }
    }

    func deleteBottle(_ bottle: Bottle, deleteFiles: Bool) async {
        do {
            if let executor { try? await executor.killBottle(bottle) }
            try await bottleStore.remove(bottle, deleteFiles: deleteFiles)
            if selectedBottleID == bottle.id { selectedBottleID = nil }
            await refresh()
        } catch {
            lastError = "Couldn't delete configuration: \(error.localizedDescription)"
        }
    }

    func renameBottle(_ bottle: Bottle, to name: String) async {
        do {
            _ = try await bottleStore.rename(bottle, to: name)
            await refresh()
        } catch {
            lastError = "Couldn't rename configuration: \(error.localizedDescription)"
        }
    }

    /// Saves changed settings and applies any that live in the Wine prefix
    /// (Windows version change reruns winecfg; registry settings reapply).
    func applySettings(_ settings: BottleSettings, to bottle: Bottle) async {
        var updated = bottle
        let oldVersion = bottle.settings.windowsVersion
        updated.settings = settings
        do {
            try await bottleStore.update(updated)
            await refresh()
            guard let executor else { return }
            busyBottleIDs.insert(bottle.id)
            defer { busyBottleIDs.remove(bottle.id) }
            if settings.windowsVersion != oldVersion {
                try await executor.changeWindowsVersion(settings.windowsVersion, bottle: updated)
            }
            if settings.graphicsBackend != bottle.settings.graphicsBackend {
                try GraphicsBackendDeployer.apply(
                    settings.graphicsBackend, runtime: executor.runtime, bottle: updated
                )
            }
            try await executor.applyRegistrySettings(for: updated)
        } catch {
            lastError = "Couldn't apply settings: \(error.localizedDescription)"
        }
    }

    func launchTool(_ tool: WineExecutor.WineTool, in bottle: Bottle) {
        guard let executor else { return }
        executor.launchTool(tool, bottle: bottle)
    }

    // MARK: Steam

    func installSteam(in bottle: Bottle) async {
        guard let executor else {
            lastError = "Install the runtime first."
            return
        }
        steamProgress[bottle.id] = .downloading(bytesDownloaded: 0, totalBytes: nil)
        defer { steamProgress[bottle.id] = nil }
        do {
            _ = try await SteamInstaller().install(in: bottle, executor: executor) { progress in
                Task { @MainActor [weak self] in self?.steamProgress[bottle.id] = progress }
            }
            await refresh()
        } catch {
            lastError = "Steam install failed: \(error.localizedDescription)"
        }
    }

    func launchSteam(in bottle: Bottle) {
        guard let executor else { return }
        steamRunning.insert(bottle.id)
        steamClientVisible.remove(bottle.id)
        steamClientRequestedVisible.remove(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        let session = SteamInstaller().launch(in: bottle, executor: executor)
        Task { [weak self] in
            await session.task.value
            self?.steamRunning.remove(bottle.id)
            self?.forgetSteamClientPID(for: bottle)
            self?.refreshGames(in: bottle)
        }
    }

    /// Launches a game via Steam (`-applaunch`); Steam boots first if needed.
    /// With `debugLogging`, Wine runs with verbose diagnostics and the session
    /// log opens in Console.app so output can be watched live.
    func launchGame(_ game: InstalledGame, in bottle: Bottle, debugLogging: Bool = false) {
        guard let executor else { return }
        guard gameRunStates[game.id] == nil else { return } // already starting/running
        gameStateLog.log("\(game.name, privacy: .public): starting")
        gameRunStates[game.id] = .starting
        watchGame(game)
        steamRunning.insert(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        let session = SteamInstaller().launchGame(
            game, in: bottle, executor: executor, debugLogging: debugLogging
        )
        if debugLogging, let logURL = session.logFileURL {
            openLogInConsole(logURL)
        }
        Task { [weak self] in
            await session.task.value
            self?.steamRunning.remove(bottle.id)
            self?.refreshGames(in: bottle)
        }
    }

    /// Opens a session log in Console.app (which follows appended lines live);
    /// falls back to revealing it in Finder.
    private func openLogInConsole(_ url: URL) {
        let console = URL(filePath: "/System/Applications/Utilities/Console.app")
        NSWorkspace.shared.open(
            [url], withApplicationAt: console, configuration: NSWorkspace.OpenConfiguration()
        ) { _, error in
            if error != nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    /// Tracks a launched game's real process through its lifecycle: waits for
    /// it to appear (Steam boot + game boot can be slow — generous timeout,
    /// after which the state reverts so a failed launch doesn't wedge the
    /// Play button), then watches until it disappears — normal quit and crash
    /// look the same and both return the tile to "not running".
    private func watchGame(_ game: InstalledGame, startupTimeout: Duration = .seconds(300)) {
        gameWatchers[game.id]?.cancel()
        gameWatchers[game.id] = Task { [weak self] in
            let deadline = ContinuousClock.now + startupTimeout
            while !Task.isCancelled {
                if await !GameNudger.processIDs(for: game).isEmpty {
                    guard !Task.isCancelled else { return }
                    gameStateLog.log("\(game.name, privacy: .public): running")
                    self?.gameRunStates[game.id] = .running
                    break
                }
                guard ContinuousClock.now < deadline else {
                    gameStateLog.log("\(game.name, privacy: .public): startup timed out, clearing")
                    self?.gameRunStates[game.id] = nil
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            // Require two consecutive empty polls before declaring the game
            // gone — a single pgrep/lsof hiccup must not clear a live game.
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if await GameNudger.processIDs(for: game).isEmpty {
                    misses += 1
                    if misses >= 2 {
                        gameStateLog.log("\(game.name, privacy: .public): process gone, clearing")
                        self?.gameRunStates[game.id] = nil
                        return
                    }
                } else {
                    misses = 0
                }
            }
        }
    }

    /// Manual escape hatch for the Wine loading livelock: suspends and
    /// resumes the game's processes to break the spin (see `GameNudger`).
    func nudgeGame(_ game: InstalledGame) {
        Task { [weak self] in
            let nudged = await GameNudger.nudgeNow(game)
            if nudged == 0 {
                self?.lastError = "\"\(game.name)\" doesn't seem to be running."
            }
        }
    }

    /// Stops the game's Wine processes and unconditionally releases the UI's
    /// launch state. The immediate clear is intentional: this is also the
    /// recovery path when process detection is stuck on an orphaned helper.
    func forceQuitGame(_ game: InstalledGame) {
        gameStateLog.log("\(game.name, privacy: .public): force quit requested")
        gameWatchers.removeValue(forKey: game.id)?.cancel()
        gameRunStates[game.id] = nil
        Task { [weak self] in
            _ = await GameNudger.forceQuit(game)
            self?.gameRunStates[game.id] = nil
        }
    }

    /// Reveals the session-log folder in Finder.
    func showSessionLogs() {
        try? FileManager.default.createDirectory(
            at: SyntheholPaths.logs, withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(SyntheholPaths.logs)
    }

    static let steamWebAPIKeyDefaultsKey = "steamWebAPIKey"

    /// Loads the signed-in account's owned-but-not-installed games via the
    /// Steam Web API (needs the user's personal API key; set in the Library's
    /// Available to Install section).
    func refreshOwnedGames(in bottle: Bottle) async {
        guard bottle.settings.steamInstalled else { return }
        let apiKey = (UserDefaults.standard.string(forKey: Self.steamWebAPIKeyDefaultsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else { return } // view shows key setup instead
        guard let user = SteamStore().loginUsers(in: bottle).first else {
            ownedGamesError[bottle.id] = "Sign in to Steam once to see your library here."
            return
        }
        loadingOwnedGames.insert(bottle.id)
        defer { loadingOwnedGames.remove(bottle.id) }
        ownedGamesError[bottle.id] = nil
        do {
            let owned = try await SteamOwnedGamesFetcher(apiKey: apiKey)
                .ownedGames(steamID64: user.steamID64)
            let installedIDs = Set((installedGames[bottle.id] ?? []).map(\.storeGameID))
            ownedGames[bottle.id] = owned
                .filter { !SteamStore.nonGameAppIDs.contains($0.appID) }
                .filter { !installedIDs.contains(String($0.appID)) }
                .map { game in
                    InstalledGame(
                        store: SteamStore.storeID,
                        storeGameID: String(game.appID),
                        name: game.name,
                        posterURL: URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(game.appID)/library_600x900_2x.jpg")
                    )
                }
        } catch SteamOwnedGamesFetcher.FetchError.invalidKey {
            ownedGamesError[bottle.id] = "Steam rejected the API key. Check it and try again."
            UserDefaults.standard.removeObject(forKey: Self.steamWebAPIKeyDefaultsKey)
        } catch {
            ownedGamesError[bottle.id] = "Couldn't load your Steam library right now."
        }
    }

    /// Triggers Steam's install flow for an owned game.
    func installOwnedGame(_ game: InstalledGame, in bottle: Bottle) {
        guard let executor else { return }
        steamRunning.insert(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        activateExistingWineWindowsSoon()
        let session = SteamInstaller().requestInstall(
            appID: game.storeGameID, in: bottle, executor: executor
        )
        Task { [weak self] in
            await session.task.value
            self?.steamRunning.remove(bottle.id)
            self?.refreshGames(in: bottle)
        }
    }

    /// Triggers Steam's own uninstall flow for a game (Steam shows the
    /// confirmation dialog and removes the files).
    func uninstallGame(_ game: InstalledGame, in bottle: Bottle) {
        guard let executor else { return }
        steamRunning.insert(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        activateExistingWineWindowsSoon()
        let session = SteamInstaller().requestUninstall(of: game, in: bottle, executor: executor)
        Task { [weak self] in
            await session.task.value
            self?.steamRunning.remove(bottle.id)
            self?.refreshGames(in: bottle)
        }
    }

    /// Brings existing Wine windows forward after a short delay. Used when an
    /// action surfaces UI *inside* an already-open window — Steam renders its
    /// install/uninstall confirmations as modals within the client window, so
    /// no new OS window ever appears for the new-window watcher to activate.
    private func activateExistingWineWindowsSoon(afterSeconds delay: Double = 2.5) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []
            var pids: Set<pid_t> = []
            for window in info {
                guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let owner = (window[kCGWindowOwnerName as String] as? String)?.lowercased(),
                      owner == "wine" || owner.hasSuffix(".exe") || owner.contains("wine"),
                      let pid = window[kCGWindowOwnerPID as String] as? Int
                else { continue }
                pids.insert(pid_t(pid))
            }
            for pid in pids {
                guard let app = NSRunningApplication(processIdentifier: pid),
                      !app.isActive else { continue }
                NSApp.yieldActivation(to: app)
                app.activate()
            }
        }
    }

    /// Wine processes aren't launched through LaunchServices, so macOS never
    /// makes their windows frontmost (under Stage Manager they land in the side
    /// strip as background apps). After triggering something that surfaces Wine
    /// UI, watch the window server for newly appearing Wine-owned windows and
    /// hand the owning app activation. Window-based (not process-based) so
    /// dialogs opened by an already-running Steam count too — e.g. the
    /// steam://uninstall confirmation.
    private func watchNewWineWindows(
        hidingSteamIn bottle: Bottle? = nil, deadline: TimeInterval = 90
    ) {
        func wineWindows(options: CGWindowListOption = [
            .optionOnScreenOnly, .excludeDesktopElements
        ]) -> [(id: UInt32, pid: pid_t, title: String)] {
            let info = CGWindowListCopyWindowInfo(
                options, kCGNullWindowID
            ) as? [[String: Any]] ?? []
            return info.compactMap { window in
                guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                      let owner = (window[kCGWindowOwnerName as String] as? String)?.lowercased(),
                      owner.hasSuffix(".exe") || owner.contains("wine"),
                      let id = window[kCGWindowNumber as String] as? Int,
                      let pid = window[kCGWindowOwnerPID as String] as? Int
                else { return nil }
                let title = window[kCGWindowName as String] as? String ?? ""
                return (UInt32(id), pid_t(pid), title)
            }
        }

        var seen = Set(wineWindows().map(\.id))
        Task { @MainActor in
            var lastActivation: [pid_t: Date] = [:]
            let start = Date()
            while Date().timeIntervalSince(start) < deadline {
                try? await Task.sleep(for: .seconds(1))
                for window in wineWindows() {
                    if let bottle,
                       Self.isSteamWindowTitle(window.title)
                        || Self.isSteamClientProcess(window.pid) {
                        rememberSteamClientPID(window.pid, for: bottle)
                        if steamClientRequestedVisible.contains(bottle.id) {
                            guard !steamClientVisible.contains(bottle.id) else { continue }
                            if let app = NSRunningApplication(processIdentifier: window.pid) {
                                app.unhide()
                                NSApp.yieldActivation(to: app)
                                app.activate()
                                steamClientVisible.insert(bottle.id)
                            }
                        } else {
                            steamClientVisible.remove(bottle.id)
                            NSRunningApplication(processIdentifier: window.pid)?.hide()
                        }
                        continue
                    }
                    guard !seen.contains(window.id) else { continue }
                    seen.insert(window.id)
                    // Per-app cooldown so multi-window boots don't churn focus.
                    if let last = lastActivation[window.pid],
                       Date().timeIntervalSince(last) < 3 { continue }
                    guard let app = NSRunningApplication(processIdentifier: window.pid),
                          !app.isActive else { continue }
                    NSApp.yieldActivation(to: app)
                    app.activate()
                    lastActivation[window.pid] = Date()
                }
            }
        }
    }

    private static func isSteamWindowTitle(_ title: String) -> Bool {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == "steam" || value.hasPrefix("steam - ")
    }

    /// Window titles are blank unless the user grants Screen Recording access.
    /// Wine exposes the Windows executable as its process name, so this remains
    /// reliable without adding a privacy permission just to hide Steam.
    private static func isSteamClientProcess(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4_096)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return false }
        let name = String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)), as: UTF8.self)
            .lowercased()
        return name.hasSuffix("steamwebhelper.exe")
    }

    /// Hides an adopted/already-running Steam window. Uses the Window Server
    /// owner PID so only Steam's Wine process is hidden; game windows belong
    /// to different Wine processes.
    private func hideSteamClientSoon(in bottle: Bottle) {
        Task { @MainActor in
            for _ in 0..<20 {
                guard !steamClientRequestedVisible.contains(bottle.id) else { return }
                if setSteamClientVisible(false, in: bottle) { return }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    /// Toggles Steam without affecting games. Returns false internally when
    /// Steam has not created its window yet, allowing the startup poll to retry.
    @discardableResult
    private func setSteamClientVisible(_ visible: Bool, in bottle: Bottle) -> Bool {
        var pid = steamClientPIDs[bottle.id] ?? persistedSteamClientPID(for: bottle)
        if let cached = pid,
           NSRunningApplication(processIdentifier: cached) == nil
            || !Self.isSteamClientProcess(cached) {
            forgetSteamClientPID(for: bottle)
            pid = nil
        }
        if pid == nil {
            let info = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []
            pid = info.first { window in
                let title = window[kCGWindowName as String] as? String ?? ""
                guard let rawPID = window[kCGWindowOwnerPID as String] as? Int else {
                    return false
                }
                return Self.isSteamWindowTitle(title)
                    || Self.isSteamClientProcess(pid_t(rawPID))
            }.flatMap { ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) }
        }
        guard let pid, let app = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        rememberSteamClientPID(pid, for: bottle)
        if visible {
            app.unhide()
            NSApp.yieldActivation(to: app)
            app.activate()
            steamClientVisible.insert(bottle.id)
        } else {
            app.hide()
            steamClientVisible.remove(bottle.id)
        }
        return true
    }

    func toggleSteamClient(in bottle: Bottle) {
        let show = !steamClientVisible.contains(bottle.id)
        if show {
            steamClientRequestedVisible.insert(bottle.id)
        } else {
            steamClientRequestedVisible.remove(bottle.id)
        }
        if !setSteamClientVisible(show, in: bottle), show {
            // Ask an existing Steam process to surface its main window, then
            // capture and show the Wine process that owns it.
            guard let executor else { return }
            let stream = executor.runProgram(
                at: SteamStore().steamExecutable(in: bottle),
                arguments: ["steam://open/main"], bottle: bottle
            )
            Task.detached(priority: .utility) { for try await _ in stream {} }
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if setSteamClientVisible(true, in: bottle) { return }
                }
            }
        }
    }

    /// Refreshes the installed-games list and keeps the steamapps watcher alive.
    func refreshGames(in bottle: Bottle) {
        installedGames[bottle.id] = (try? SteamStore().installedGames(in: bottle)) ?? []
        // Newly installed games leave the available-to-install list.
        let installedIDs = Set((installedGames[bottle.id] ?? []).map(\.storeGameID))
        ownedGames[bottle.id]?.removeAll { installedIDs.contains($0.storeGameID) }
        startWatchingIfNeeded(bottle)
        loadMetadata(for: installedGames[bottle.id] ?? [])
    }

    /// Fills `gameMetadata` for games that don't have it yet (disk-cached,
    /// so this is usually instant after first launch).
    private func loadMetadata(for games: [InstalledGame]) {
        let missing = games.filter { gameMetadata[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task { [weak self, metadataStore] in
            for game in missing {
                guard let metadata = await metadataStore.metadata(forAppID: game.storeGameID)
                else { continue }
                self?.gameMetadata[game.id] = metadata
            }
        }
    }

    /// Poster image for a game, from the artwork cache (memory → disk → CDN →
    /// Steam's own librarycache in the bottle).
    func poster(for game: InstalledGame, in bottle: Bottle) async -> NSImage? {
        if let image = posterImages[game.id] { return image }
        let store = SteamStore()
        let data = await artworkCache.poster(
            for: game,
            remoteCandidates: store.remoteArtworkCandidates(for: game),
            localFallbacks: store.localArtworkFallbacks(for: game, in: bottle)
        )
        guard let data, let image = NSImage(data: data) else { return nil }
        posterImages[game.id] = image
        return image
    }

    private func startWatchingIfNeeded(_ bottle: Bottle) {
        guard watchers[bottle.id] == nil, bottle.settings.steamInstalled else { return }
        let steamapps = SteamStore().steamDirectory(in: bottle).appending(path: "steamapps")
        let bottleURL = bottle.url
        watchers[bottle.id] = DirectoryWatcher(url: steamapps) { [weak self] in
            guard let self, let fresh = try? Bottle.load(from: bottleURL) else { return }
            self.refreshGames(in: fresh)
        }
    }

    /// Asks Steam to exit cleanly; the launch monitor then stops the bottle.
    func quitSteam(in bottle: Bottle) async {
        guard let executor else { return }
        await SteamInstaller().requestExit(in: bottle, executor: executor)
    }

    /// Stops everything in a bottle: graceful Steam exit first (if installed),
    /// then wineserver shutdown.
    func stopBottle(_ bottle: Bottle) async {
        guard let executor else { return }
        busyBottleIDs.insert(bottle.id)
        defer { busyBottleIDs.remove(bottle.id) }
        let steam = SteamInstaller()
        if bottle.settings.steamInstalled {
            await steam.requestExit(in: bottle, executor: executor)
            for _ in 0..<5 {
                if await !steam.isRunning(in: bottle) { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        try? await executor.killBottle(bottle)
    }
}
