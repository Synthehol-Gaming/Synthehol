import AppKit
import Foundation
import Observation
import SyntheholKit

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
    var lastError: String?

    private let artworkCache = ArtworkCache()
    private var posterImages: [String: NSImage] = [:]
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
    }

    // MARK: Runtime

    func installRuntime() async {
        runtimeProgress = .downloading(bytesDownloaded: 0, totalBytes: nil)
        defer { runtimeProgress = nil }
        do {
            runtime = try await runtimeStore.install(RuntimeManifest.stableDefault) { progress in
                Task { @MainActor [weak self] in self?.runtimeProgress = progress }
            }
        } catch {
            lastError = "Runtime install failed: \(error.localizedDescription)"
        }
    }

    // MARK: Bottles

    func createBottle(name: String, windowsVersion: WindowsVersion) async {
        guard let executor else {
            lastError = "Install the Wine runtime before creating a bottle."
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
            await refresh()
        } catch {
            lastError = "Couldn't create bottle: \(error.localizedDescription)"
        }
    }

    func deleteBottle(_ bottle: Bottle, deleteFiles: Bool) async {
        do {
            if let executor { try? await executor.killBottle(bottle) }
            try await bottleStore.remove(bottle, deleteFiles: deleteFiles)
            if selectedBottleID == bottle.id { selectedBottleID = nil }
            await refresh()
        } catch {
            lastError = "Couldn't delete bottle: \(error.localizedDescription)"
        }
    }

    func renameBottle(_ bottle: Bottle, to name: String) async {
        do {
            _ = try await bottleStore.rename(bottle, to: name)
            await refresh()
        } catch {
            lastError = "Couldn't rename bottle: \(error.localizedDescription)"
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
            lastError = "Install the Wine runtime first."
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
        let monitor = SteamInstaller().launch(in: bottle, executor: executor)
        Task { [weak self] in
            await monitor.value
            self?.steamRunning.remove(bottle.id)
            self?.refreshGames(in: bottle)
        }
    }

    /// Launches a game via Steam (`-applaunch`); Steam boots first if needed.
    func launchGame(_ game: InstalledGame, in bottle: Bottle) {
        guard let executor else { return }
        steamRunning.insert(bottle.id)
        let monitor = SteamInstaller().launchGame(game, in: bottle, executor: executor)
        Task { [weak self] in
            await monitor.value
            self?.steamRunning.remove(bottle.id)
            self?.refreshGames(in: bottle)
        }
    }

    /// Refreshes the installed-games list and keeps the steamapps watcher alive.
    func refreshGames(in bottle: Bottle) {
        installedGames[bottle.id] = (try? SteamStore().installedGames(in: bottle)) ?? []
        startWatchingIfNeeded(bottle)
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
                if await !executor.isProcessRunning(imageName: "steam.exe", bottle: bottle) { break }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        try? await executor.killBottle(bottle)
    }
}
