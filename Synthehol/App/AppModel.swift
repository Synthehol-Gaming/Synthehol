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
    var lastError: String?

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
        SteamInstaller().launch(in: bottle, executor: executor)
    }

    /// Refreshes the installed-games preview for a bottle (full library UI is Phase 4).
    func refreshGames(in bottle: Bottle) {
        installedGames[bottle.id] = (try? SteamStore().installedGames(in: bottle)) ?? []
    }
}
