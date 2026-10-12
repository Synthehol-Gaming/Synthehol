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
    private static let selectedBottleDefaultsKey = "selectedBottleID"
    private static let nativeSteamSelectedDefaultsKey = "nativeSteamSelected"
    private static let steamWebAPIKeysDefaultsKey = "steamWebAPIKeys"
    private static let legacySteamWebAPIKeyDefaultsKey = "steamWebAPIKey"
    private static let nativeSteamWebAPIKeyIDDefaultsKey = "nativeSteamWebAPIKeyID"
    private static let showNativeSteamVRGamesDefaultsKey = "showNativeSteamVRGames"

    struct SteamWebAPIKeyProfile: Codable, Identifiable, Equatable {
        let id: String
        var name: String
        var key: String

        var displayName: String {
            let suffix = String(key.suffix(4))
            return suffix.isEmpty ? name : "\(name) (••••\(suffix))"
        }
    }

    let bottleStore = BottleStore()
    let runtimeStore = RuntimeStore()

    var bottles: [Bottle] = []
    var nativeSteamSelected = false {
        didSet { UserDefaults.standard.set(nativeSteamSelected, forKey: Self.nativeSteamSelectedDefaultsKey) }
    }
    var nativeSteamGames: [InstalledGame] = []
    var nativeOwnedGames: [InstalledGame] = []
    var nativeOwnedGamesError: String?
    var loadingNativeOwnedGames = false
    var showNativeSteamVRGames = true {
        didSet {
            UserDefaults.standard.set(
                showNativeSteamVRGames, forKey: Self.showNativeSteamVRGamesDefaultsKey
            )
        }
    }
    var nativeSteamWebAPIKeyID: String? {
        didSet {
            UserDefaults.standard.set(
                nativeSteamWebAPIKeyID, forKey: Self.nativeSteamWebAPIKeyIDDefaultsKey
            )
        }
    }
    var nativeSteamStatus = NativeSteamCompatibilityStatus(deployment: .notInstalled)
    let nativeSteamStore = NativeSteamStore()
    let nativeGameSettingsDirectory = SyntheholPaths.applicationSupport
        .appending(path: "NativeSteam/Game Settings")
    var bottleStorages: [BottleStorage] = []
    var steamWebAPIKeys: [SteamWebAPIKeyProfile] = []
    private var migratedLegacySteamWebAPIKeyID: String?
    var selectedBottleID: Bottle.ID? {
        didSet {
            guard selectedBottleID != oldValue else { return }
            if let selectedBottleID {
                UserDefaults.standard.set(
                    selectedBottleID, forKey: Self.selectedBottleDefaultsKey
                )
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedBottleDefaultsKey)
            }
        }
    }
    var runtime: WineRuntime?
    var runtimeProgress: RuntimeInstallProgress?
    var busyBottleIDs: Set<Bottle.ID> = []
    var steamProgress: [Bottle.ID: SteamInstaller.Progress] = [:]
    var installerRunning: Set<Bottle.ID> = []
    var installedGames: [Bottle.ID: [InstalledGame]] = [:]
    var steamRunning: Set<Bottle.ID> = []
    enum SteamTransition: Equatable { case starting, stopping, stopTimedOut }
    var steamTransitions: [Bottle.ID: SteamTransition] = [:]
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
    var needsAppManagementPermission = false

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

    init() {
        nativeSteamSelected = UserDefaults.standard.bool(forKey: Self.nativeSteamSelectedDefaultsKey)
        nativeSteamWebAPIKeyID = UserDefaults.standard.string(
            forKey: Self.nativeSteamWebAPIKeyIDDefaultsKey
        )
        if UserDefaults.standard.object(forKey: Self.showNativeSteamVRGamesDefaultsKey) != nil {
            showNativeSteamVRGames = UserDefaults.standard.bool(
                forKey: Self.showNativeSteamVRGamesDefaultsKey
            )
        }
        if let data = UserDefaults.standard.data(forKey: Self.steamWebAPIKeysDefaultsKey),
           let profiles = try? JSONDecoder().decode([SteamWebAPIKeyProfile].self, from: data) {
            steamWebAPIKeys = profiles
        } else if let legacy = UserDefaults.standard.string(
            forKey: Self.legacySteamWebAPIKeyDefaultsKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty {
            let profile = SteamWebAPIKeyProfile(
                id: UUID().uuidString, name: "Default", key: legacy
            )
            steamWebAPIKeys = [profile]
            migratedLegacySteamWebAPIKeyID = profile.id
            saveSteamWebAPIKeys()
            UserDefaults.standard.removeObject(forKey: Self.legacySteamWebAPIKeyDefaultsKey)
        }
        if nativeSteamWebAPIKeyID == nil, steamWebAPIKeys.count == 1 {
            nativeSteamWebAPIKeyID = steamWebAPIKeys[0].id
        }
    }

    /// Genres present in the selected configuration's installed library,
    /// with counts, for the sidebar filter list.
    var sidebarGenres: [(genre: String, count: Int)] {
        var counts: [String: Int] = [:]
        let games: [InstalledGame]
        if nativeSteamSelected {
            games = nativeSteamGames.filter {
                showNativeSteamVRGames || gameMetadata[$0.id]?.supportsVR != true
            }
        } else if let bottle = selectedBottle {
            games = installedGames[bottle.id] ?? []
        } else {
            games = []
        }
        for game in games {
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
        refreshNativeSteam()
        runtime = await runtimeStore.current()
        bottleStorages = await bottleStore.storageLocations()
        bottles = await bottleStore.bottles()
        for bottle in bottles {
            try? BottleDriveManager.apply(previous: bottle.settings.drives, current: bottle.settings.drives, to: bottle)
        }
        // Preserve the old one-global-key behavior during migration by
        // explicitly assigning the sole shared profile to unconfigured bottles.
        if let migratedID = migratedLegacySteamWebAPIKeyID {
            for index in bottles.indices where bottles[index].settings.steamWebAPIKeyID == nil {
                bottles[index].settings.steamWebAPIKeyID = migratedID
                try? bottles[index].saveSettings()
            }
            migratedLegacySteamWebAPIKeyID = nil
        }
        let availableIDs = Set(bottles.map(\.id))
        if let selectedBottleID, availableIDs.contains(selectedBottleID) {
            // Preserve an in-session choice across refreshes.
        } else if let persisted = UserDefaults.standard.string(
            forKey: Self.selectedBottleDefaultsKey
        ), availableIDs.contains(persisted) {
            selectedBottleID = persisted
        } else {
            // The saved configuration may have been deleted outside the app.
            selectedBottleID = bottles.first?.id
        }
        WineLogWriter.deleteOldLogs()
        await repairIncompleteD3DMetalDeployments()
        await adoptRunningSessions()
    }

    func selectNativeSteam() {
        nativeSteamSelected = true
        selectedGameFilter = .all
        refreshNativeSteam()
    }

    func selectBottle(_ id: Bottle.ID) {
        nativeSteamSelected = false
        selectedBottleID = id
        selectedGameFilter = .all
    }

    func refreshNativeSteam() {
        nativeSteamGames = (try? nativeSteamStore.installedGames()) ?? []
        nativeSteamStatus = NativeSteamCompatibilityStatus.inspect()
        loadMetadata(for: nativeSteamGames)
        for game in nativeSteamGames where posterImages[game.id] == nil {
            Task { [weak self] in _ = await self?.nativePoster(for: game) }
        }
    }

    func nativeSteamWebAPIKey() -> String? {
        guard let id = nativeSteamWebAPIKeyID else { return nil }
        return steamWebAPIKeys.first { $0.id == id }?.key
    }

    func refreshNativeOwnedGames() async {
        guard let apiKey = nativeSteamWebAPIKey(), !apiKey.isEmpty else {
            nativeOwnedGames = []
            nativeOwnedGamesError = nil
            return
        }
        guard let user = nativeSteamStore.loginUsers().first else {
            nativeOwnedGames = []
            nativeOwnedGamesError = "Sign in to the macOS Steam client once to see your library here."
            return
        }
        loadingNativeOwnedGames = true
        defer { loadingNativeOwnedGames = false }
        nativeOwnedGamesError = nil
        do {
            let owned = try await SteamOwnedGamesFetcher(apiKey: apiKey)
                .ownedGames(steamID64: user.steamID64)
            let installedIDs = Set(nativeSteamGames.map(\.storeGameID))
            nativeOwnedGames = owned
                .filter { !SteamStore.nonGameAppIDs.contains($0.appID) }
                .filter { !installedIDs.contains(String($0.appID)) }
                .map {
                    InstalledGame(
                        store: NativeSteamStore.storeID,
                        storeGameID: String($0.appID),
                        name: $0.name,
                        posterURL: URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\($0.appID)/library_600x900_2x.jpg")
                    )
                }
            loadMetadata(for: nativeOwnedGames)
        } catch SteamOwnedGamesFetcher.FetchError.invalidKey {
            nativeOwnedGames = []
            nativeOwnedGamesError = "Steam rejected the API key. Check it and try again."
        } catch {
            nativeOwnedGames = []
            nativeOwnedGamesError = "Couldn't load your Steam library right now."
        }
    }

    func installNativeOwnedGame(_ game: InstalledGame) {
        Task { [weak self, nativeSteamStore] in
            do {
                try await nativeSteamStore.requestInstall(appID: game.storeGameID)
            } catch {
                self?.lastError = "Couldn't install \"\(game.name)\": \(error.localizedDescription)"
            }
        }
    }

    func launchNativeGame(_ game: InstalledGame) {
        guard gameRunStates[game.id] == nil else { return }
        guard NativeSteamBridgeProvisioner.isComplete(
            at: SyntheholPaths.applicationSupport.appending(path: "NativeSteam/bridge")
        ) else {
            lastError = "Synthehol Steam Play needs repair before this game can launch. Create a configuration with Steam installed, then choose Install or Repair on the Mac Steam page."
            return
        }
        let settings = GameSettings.load(for: game, in: nativeGameSettingsDirectory)
        gameRunStates[game.id] = .starting
        if settings.nudgeStuckLoading {
            _ = GameNudger.startMonitor(for: game) { event in
                gameStateLog.log("[native nudge] \(event, privacy: .public)")
            }
        }
        Task { [weak self, nativeSteamStore] in
            do {
                try await nativeSteamStore.launch(game)
                self?.gameRunStates[game.id] = nil
            } catch {
                self?.gameRunStates[game.id] = nil
                self?.lastError = "Couldn't launch \"\(game.name)\": \(error.localizedDescription)"
            }
        }
    }

    func nativeGameSettings(for game: InstalledGame) -> GameSettings {
        GameSettings.load(for: game, in: nativeGameSettingsDirectory)
    }

    func saveNativeGameSettings(_ settings: GameSettings, for game: InstalledGame) {
        do {
            try settings.save(for: game, in: nativeGameSettingsDirectory)
            try NativeSteamPerformanceProfileStore.save(settings, appID: game.storeGameID)
        } catch {
            lastError = "Couldn't save settings for \"\(game.name)\": \(error.localizedDescription)"
        }
    }

    func launchNativeSteam() {
        Task { [weak self, nativeSteamStore] in
            do {
                let result = try await ProcessRunner.run(
                    executable: URL(filePath: "/usr/bin/open"),
                    arguments: ["-a", nativeSteamStore.steamApplication.path(percentEncoded: false)]
                )
                if result.exitCode != 0 {
                    self?.lastError = "Steam could not be opened."
                }
            } catch {
                self?.lastError = "Steam could not be opened: \(error.localizedDescription)"
            }
        }
    }

    func installNativeSteamCompatibility() async {
        needsAppManagementPermission = false
        do {
            let payload = try NativeSteamPayload.bundled()
            try await NativeSteamInstaller.install(payload: payload, bottles: bottles)
            nativeSteamStatus = NativeSteamCompatibilityStatus.inspect()
        } catch NativeSteamInstallError.appManagementPermissionRequired {
            needsAppManagementPermission = true
            lastError = NativeSteamInstallError.appManagementPermissionRequired.localizedDescription
        } catch {
            lastError = "Couldn't install Synthehol Steam Play: \(error.localizedDescription)"
        }
    }

    func openAppManagementSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AppBundles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func repairNativeSteam() async {
        do {
            try await NativeSteamInstaller.repair()
            nativeSteamStatus = NativeSteamCompatibilityStatus.inspect()
        } catch {
            lastError = "Couldn't repair Steam: \(error.localizedDescription)"
        }
    }

    func nativePoster(for game: InstalledGame) async -> NSImage? {
        if let existing = posterImages[game.id] { return existing }
        let steam = SteamStore()
        let data = await artworkCache.poster(
            for: game,
            remoteCandidates: steam.remoteArtworkCandidates(for: game),
            localFallbacks: nativeSteamStore.localArtworkFallbacks(for: game)
        )
        guard let data, let image = NSImage(data: data) else { return nil }
        posterImages[game.id] = image
        return image
    }

    /// Clears custom/cached native-Steam artwork and reloads Valve's default.
    func resetNativePoster(for game: InstalledGame) async {
        await artworkCache.resetPoster(forGameID: game.id)
        posterImages.removeValue(forKey: game.id)
        _ = await nativePoster(for: game)
    }

    func showNativeGameLogs(for game: InstalledGame) {
        let fm = FileManager.default
        let logs = nativeSteamStore.diagnosticLogs(for: game).filter {
            fm.fileExists(atPath: $0.path(percentEncoded: false))
        }
        guard !logs.isEmpty else {
            lastError = "No logs exist for \"\(game.name)\" yet. Launch it once with Synthehol Steam Play, then try again."
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(logs)
    }

    func showNativeSteamPlayLog() {
        let log = nativeSteamStore.clientLog()
        guard FileManager.default.fileExists(atPath: log.path(percentEncoded: false)) else {
            lastError = "The Steam Play client log has not been created yet. Fully quit and reopen Steam after installing Synthehol Steam Play."
            return
        }
        NSWorkspace.shared.open(log)
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
            steamClientRequestedVisible.remove(bottle.id)
            watchNewWineWindows(hidingSteamIn: bottle)
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

    func installLocalRuntime(from sidecar: URL) async {
        runtimeProgress = .verifying
        defer { runtimeProgress = nil }
        do {
            let installed = try await runtimeStore.installLocalManifest(at: sidecar) { progress in
                Task { @MainActor [weak self] in self?.runtimeProgress = progress }
            }
            guard installed.supportsPerformanceProfiles else {
                throw RuntimeStoreError.invalidLocalManifest
            }
            runtime = installed
            await redeployBackendsAfterRuntimeChange()
        } catch {
            lastError = "Performance runtime import failed: \(error.localizedDescription)"
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

    /// Asks for the mounted supported GPTK 4 volume and imports its libraries.
    func importGPTK() async {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the mounted Game Porting Toolkit 4 beta 2 evaluation environment (or its \"redist\" folder)."
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

    /// Installs the Wine 11.15 host runtime used by both Steam and GPTK 4.
    func installD3DMetalRuntime() async {
        await installRuntime(.gptkBeta)
    }

    // MARK: Bottles

    func createBottle(
        name: String, windowsVersion: WindowsVersion,
        storageID: BottleStorage.ID = BottleStorage.defaultID
    ) async {
        guard let executor else {
            lastError = "Install the runtime before creating a configuration."
            return
        }
        guard await Task.detached(operation: { Rosetta2.isInstalled }).value else {
            lastError = "Rosetta 2 is required to run Windows games. Install it in Terminal with: softwareupdate --install-rosetta"
            return
        }
        do {
            let bottle = try await bottleStore.create(
                name: name, windowsVersion: windowsVersion, storageID: storageID
            )
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

    func addBottleStorage(name: String, url: URL) async {
        do {
            _ = try await bottleStore.addStorage(name: name, url: url)
            bottleStorages = await bottleStore.storageLocations()
            bottles = await bottleStore.bottles()
        } catch {
            lastError = "Couldn't add bottle storage: \(error.localizedDescription)"
        }
    }

    func removeBottleStorage(_ storage: BottleStorage) async {
        do {
            try await bottleStore.removeStorage(id: storage.id)
            bottleStorages = await bottleStore.storageLocations()
        } catch {
            lastError = "Couldn't remove bottle storage: \(error.localizedDescription)"
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
        let oldDrives = bottle.settings.drives
        updated.settings = settings
        do {
            try BottleDriveManager.apply(previous: oldDrives, current: settings.drives, to: updated)
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
        guard steamTransitions[bottle.id] == nil,
              !steamRunning.contains(bottle.id) else { return }
        steamTransitions[bottle.id] = .starting
        steamClientRequestedVisible.remove(bottle.id)
        steamClientVisible.remove(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        hideSteamClientSoon(in: bottle)
        let session = SteamInstaller().launch(in: bottle, executor: executor)
        Task { [weak self] in
            let steam = SteamInstaller()
            let deadline = ContinuousClock.now + .seconds(45)
            while ContinuousClock.now < deadline {
                guard self?.steamTransitions[bottle.id] == .starting else { return }
                if await steam.isRunning(in: bottle) {
                    self?.steamRunning.insert(bottle.id)
                    self?.steamTransitions[bottle.id] = nil
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            guard self?.steamTransitions[bottle.id] == .starting else { return }
            self?.steamTransitions[bottle.id] = nil
            self?.lastError = "Steam did not start within 45 seconds."
        }
        Task { [weak self] in
            await session.task.value
            self?.steamRunning.remove(bottle.id)
            self?.steamTransitions[bottle.id] = nil
            self?.forgetSteamClientPID(for: bottle)
            self?.refreshGames(in: bottle)
        }
    }

    /// Launches a game via Steam (`-applaunch`); Steam boots first if needed.
    /// With `debugLogging`, Wine runs with verbose diagnostics and the session
    /// log opens in Console.app so output can be watched live.
    func launchGame(_ game: InstalledGame, in bottle: Bottle, debugLogging: Bool = false) {
        guard let executor else { return }
        if game.store == CustomGameStore.storeID {
            launchCustomGame(game, in: bottle, executor: executor, debugLogging: debugLogging)
            return
        }
        guard gameRunStates[game.id] == nil else { return } // already starting/running
        gameStateLog.log("\(game.name, privacy: .public): starting")
        gameRunStates[game.id] = .starting
        watchGame(game)
        steamRunning.insert(bottle.id)
        steamClientRequestedVisible.remove(bottle.id)
        steamClientVisible.remove(bottle.id)
        watchNewWineWindows(hidingSteamIn: bottle)
        hideSteamClientSoon(in: bottle)
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

    private func launchCustomGame(
        _ game: InstalledGame, in bottle: Bottle, executor: WineExecutor,
        debugLogging: Bool
    ) {
        guard gameRunStates[game.id] == nil,
              let path = game.executablePath else { return }
        let executable = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            lastError = "The executable for \"\(game.name)\" could not be found."
            return
        }
        let settings = GameSettings.load(for: game, in: bottle)
        gameRunStates[game.id] = .starting
        watchGame(game)
        let profileEnvironment = settings.effectiveEnvironment(
            supportsPerformanceProfiles: executor.runtime.supportsPerformanceProfiles
        )
        let extra = debugLogging
            ? profileEnvironment.merging(["WINEDEBUG": "+timestamp,+pid,+tid,+seh,+module,+d3d,+dxgi"]) { _, new in new }
            : profileEnvironment
        let stream = executor.runProgram(
            at: executable, arguments: settings.launchArgumentList,
            bottle: bottle, waitForExit: true,
            workingDirectory: game.workingDirectory.map { URL(filePath: $0) },
            extraEnvironment: extra
        )
        Task { [weak self] in
            do { for try await _ in stream {} }
            catch { self?.lastError = "Couldn't launch \"\(game.name)\": \(error.localizedDescription)" }
            self?.gameRunStates[game.id] = nil
        }
    }

    func addCustomGame(
        name: String, executable: URL, workingDirectory: URL, in bottle: Bottle
    ) async -> Bool {
        do {
            _ = try CustomGameStore().add(
                name: name, executable: executable,
                workingDirectory: workingDirectory, in: bottle
            )
            refreshGames(in: bottle)
            return true
        } catch {
            lastError = "Couldn't add game: \(error.localizedDescription)"
            return false
        }
    }

    func renameCustomGame(_ game: InstalledGame, to name: String, in bottle: Bottle) {
        do {
            try CustomGameStore().rename(gameID: game.storeGameID, to: name, in: bottle)
            refreshGames(in: bottle)
        } catch {
            lastError = "Couldn't rename game: \(error.localizedDescription)"
        }
    }

    func removeCustomGame(_ game: InstalledGame, in bottle: Bottle) {
        do {
            try CustomGameStore().remove(gameID: game.storeGameID, in: bottle)
            installedGames[bottle.id]?.removeAll { $0.id == game.id }
        } catch {
            lastError = "Couldn't remove game: \(error.localizedDescription)"
        }
    }

    func runInstaller(_ installer: URL, in bottle: Bottle) {
        guard let executor else { return }
        guard !installerRunning.contains(bottle.id) else { return }
        installerRunning.insert(bottle.id)
        let stream = executor.runProgram(
            at: installer, bottle: bottle, waitForExit: true,
            workingDirectory: installer.deletingLastPathComponent()
        )
        Task { [weak self] in
            defer { self?.installerRunning.remove(bottle.id) }
            do { for try await _ in stream {} }
            catch { self?.lastError = "Couldn't run installer: \(error.localizedDescription)" }
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

    func addSteamWebAPIKey(name: String, key: String) -> String {
        let profile = SteamWebAPIKeyProfile(
            id: UUID().uuidString,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Steam Key" : name.trimmingCharacters(in: .whitespacesAndNewlines),
            key: key.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        steamWebAPIKeys.append(profile)
        steamWebAPIKeys.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        saveSteamWebAPIKeys()
        return profile.id
    }

    func removeSteamWebAPIKey(id: String) {
        steamWebAPIKeys.removeAll { $0.id == id }
        if nativeSteamWebAPIKeyID == id {
            nativeSteamWebAPIKeyID = nil
            nativeOwnedGames = []
            nativeOwnedGamesError = nil
        }
        saveSteamWebAPIKeys()
        for index in bottles.indices where bottles[index].settings.steamWebAPIKeyID == id {
            bottles[index].settings.steamWebAPIKeyID = nil
            try? bottles[index].saveSettings()
            ownedGames[bottles[index].id] = []
            ownedGamesError[bottles[index].id] = nil
        }
    }

    func steamWebAPIKey(for bottle: Bottle) -> String? {
        guard let id = bottle.settings.steamWebAPIKeyID else { return nil }
        return steamWebAPIKeys.first { $0.id == id }?.key
    }

    private func saveSteamWebAPIKeys() {
        guard let data = try? JSONEncoder().encode(steamWebAPIKeys) else { return }
        UserDefaults.standard.set(data, forKey: Self.steamWebAPIKeysDefaultsKey)
    }

    /// Loads the signed-in account's owned-but-not-installed games via the
    /// Steam Web API (needs the user's personal API key; set in the Library's
    /// Available to Install section).
    func refreshOwnedGames(in bottle: Bottle) async {
        guard bottle.settings.steamInstalled else { return }
        guard let apiKey = steamWebAPIKey(for: bottle), !apiKey.isEmpty else {
            ownedGames[bottle.id] = []
            ownedGamesError[bottle.id] = nil
            return
        }
        guard let user = SteamStore().loginUsers(in: bottle).first else {
            ownedGamesError[bottle.id] = "Sign in to Steam once to see your library here."
            return
        }
        loadingOwnedGames.insert(bottle.id)
        defer { loadingOwnedGames.remove(bottle.id) }
        ownedGamesError[bottle.id] = nil
        ownedGames[bottle.id] = []
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
        } catch {
            ownedGamesError[bottle.id] = "Couldn't load your Steam library right now."
        }
    }

    /// Triggers Steam's install flow for an owned game.
    func installOwnedGame(_ game: InstalledGame, in bottle: Bottle) {
        guard let executor else { return }
        steamRunning.insert(bottle.id)
        steamClientRequestedVisible.insert(bottle.id)
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
        steamClientRequestedVisible.insert(bottle.id)
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
            || name.hasSuffix("steamwebhelper_real.exe")
    }

    /// Steam starts one WebHelper, then the compatibility deployment restarts
    /// it. Keep applying the hidden state across that handoff so the second
    /// process cannot flash back onscreen. A manual Show Steam request stops
    /// the loop immediately.
    private func hideSteamClientSoon(in bottle: Bottle) {
        Task { @MainActor in
            for _ in 0..<30 {
                guard !steamClientRequestedVisible.contains(bottle.id) else { return }
                _ = setSteamClientVisible(false, in: bottle)
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
        let steam = (try? SteamStore().installedGames(in: bottle)) ?? []
        let custom = (try? CustomGameStore().installedGames(in: bottle)) ?? []
        installedGames[bottle.id] = (steam + custom).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        // Newly installed games leave the available-to-install list.
        let installedIDs = Set((installedGames[bottle.id] ?? []).map(\.storeGameID))
        ownedGames[bottle.id]?.removeAll { installedIDs.contains($0.storeGameID) }
        startWatchingIfNeeded(bottle)
        loadMetadata(for: installedGames[bottle.id] ?? [])
    }

    /// Fills `gameMetadata` for games that don't have it yet (disk-cached,
    /// so this is usually instant after first launch).
    private func loadMetadata(for games: [InstalledGame]) {
        let missing = games.filter {
            ($0.store == SteamStore.storeID || $0.store == NativeSteamStore.storeID)
                && gameMetadata[$0.id] == nil
        }
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
            remoteCandidates: game.store == SteamStore.storeID
                ? store.remoteArtworkCandidates(for: game) : [],
            localFallbacks: game.store == SteamStore.storeID
                ? store.localArtworkFallbacks(for: game, in: bottle) : []
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
        guard steamTransitions[bottle.id] == nil else { return }
        steamTransitions[bottle.id] = .stopping
        let steam = SteamInstaller()
        await steam.requestExit(in: bottle, executor: executor)
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if await !steam.isRunning(in: bottle) {
                steamRunning.remove(bottle.id)
                steamClientVisible.remove(bottle.id)
                forgetSteamClientPID(for: bottle)
                steamTransitions[bottle.id] = nil
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        // Do not destroy the bottle's processes without another explicit user
        // action. Surface Force Quit after graceful shutdown times out.
        steamTransitions[bottle.id] = .stopTimedOut
    }

    func forceQuitSteam(in bottle: Bottle) async {
        guard let executor,
              steamTransitions[bottle.id] == .stopTimedOut else { return }
        steamTransitions[bottle.id] = .stopping
        try? await executor.killBottle(bottle)
        steamRunning.remove(bottle.id)
        steamClientVisible.remove(bottle.id)
        forgetSteamClientPID(for: bottle)
        steamTransitions[bottle.id] = nil
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
