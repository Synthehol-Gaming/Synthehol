import Foundation

/// The user's macOS Steam installation. Windows games in this store are run by
/// the native client through Synthehol's embedded Steam-Play compatibility layer.
public struct NativeSteamStore: Sendable {
    public static let storeID = "native-steam"
    public static let displayName = "Mac Steam"

    public let steamRoot: URL
    public let steamApplication: URL

    public init(
        steamRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Steam"),
        steamApplication: URL = URL(filePath: "/Applications/Steam.app")
    ) {
        self.steamRoot = steamRoot
        self.steamApplication = steamApplication
    }

    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: steamApplication.path(percentEncoded: false))
    }

    public var defaultSteamapps: URL { steamRoot.appending(path: "steamapps") }

    /// Native paths in this VDF are already host paths; unlike bottle Steam,
    /// no drive-letter translation is appropriate.
    public func libraryFolders() -> [URL] {
        var folders = [defaultSteamapps]
        let vdf = defaultSteamapps.appending(path: "libraryfolders.vdf")
        if let text = try? String(contentsOf: vdf, encoding: .utf8),
           let root = try? ValveKeyValues.parse(text),
           case .object(let entries)? = root["libraryfolders"] {
            for (_, entry) in entries {
                guard let path = entry["path"]?.stringValue else { continue }
                let steamapps = URL(filePath: path).appending(path: "steamapps")
                if steamapps != defaultSteamapps { folders.append(steamapps) }
            }
        }
        var seen: Set<String> = []
        return folders.filter {
            let path = $0.standardizedFileURL.path(percentEncoded: false)
            return seen.insert(path).inserted
                && FileManager.default.fileExists(atPath: path)
        }
    }

    public func installedGames() throws -> [InstalledGame] {
        var games: [InstalledGame] = []
        for steamapps in libraryFolders() {
            let manifests = (try? FileManager.default.contentsOfDirectory(
                at: steamapps, includingPropertiesForKeys: nil
            )) ?? []
            for manifest in manifests
            where manifest.lastPathComponent.hasPrefix("appmanifest_")
                && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8),
                      let app = SteamApp(acf: text), app.isFullyInstalled,
                      !SteamStore.nonGameAppIDs.contains(app.appID)
                else { continue }
                games.append(InstalledGame(
                    store: Self.storeID,
                    storeGameID: String(app.appID),
                    name: app.name,
                    posterURL: app.posterURL,
                    installPath: steamapps.appending(path: "common")
                        .appending(path: app.installDirectory).path(percentEncoded: false)
                ))
            }
        }
        return games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func localArtworkFallbacks(for game: InstalledGame) -> [URL] {
        let cache = steamRoot.appending(path: "appcache/librarycache/\(game.storeGameID)")
        return [cache.appending(path: "library_600x900.jpg"), cache.appending(path: "header.jpg")]
    }

    public func prefix(for game: InstalledGame) -> URL? {
        libraryFolders().lazy
            .map { $0.appending(path: "compatdata/\(game.storeGameID)/pfx") }
            .first { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) }
    }

    /// Logs written by the Steam Play wrapper and the Wine launcher. The first
    /// lives beside the Proton-style prefix; the second captures the game's
    /// stdout/stderr after it enters the generated Game Mode app bundle.
    public func diagnosticLogs(
        for game: InstalledGame,
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam")
    ) -> [URL] {
        var logs = libraryFolders().map {
            $0.appending(path: "compatdata/\(game.storeGameID)/synthehol-run.log")
        }
        logs.append(support.appending(
            path: "launchers/\(game.storeGameID)/synthehol-wine.log"
        ))
        if let prefix = prefix(for: game),
           let enumerator = FileManager.default.enumerator(
               at: prefix.appending(path: "drive_c/users"),
               includingPropertiesForKeys: [.isRegularFileKey],
               options: [.skipsHiddenFiles]
           ) {
            for case let url as URL in enumerator
            where url.lastPathComponent == "Player.log" || url.lastPathComponent == "Player-prev.log" {
                logs.append(url)
            }
        }
        return logs
    }

    public func clientLog(
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam")
    ) -> URL {
        support.appending(path: "synthehol.log")
    }

    /// Uses argv-based Process launching; Steam owns compatibility-tool choice,
    /// downloads, DRM, overlay, and the lifetime of the resulting game.
    public func launch(_ game: InstalledGame) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/open"),
            arguments: ["-g", "steam://rungameid/\(game.storeGameID)"]
        )
        guard result.exitCode == 0 else {
            throw NativeSteamError.launchFailed(result.standardError)
        }
    }

    /// Opens Steam's native install dialog for an owned game.
    public func requestInstall(appID: String) async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/open"),
            arguments: ["-g", "steam://install/\(appID)"]
        )
        guard result.exitCode == 0 else {
            throw NativeSteamError.launchFailed(result.standardError)
        }
    }
}

public enum NativeSteamError: Error, LocalizedError {
    case launchFailed(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            return detail.isEmpty ? "Steam could not launch the game." : detail
        }
    }
}

/// Installation state for Synthehol's embedded native Steam layer. Keeping this
/// separate from game discovery lets native Steam remain useful while a client
/// update requires a new, verified injection payload.
public struct NativeSteamCompatibilityStatus: Sendable, Equatable {
    public enum Deployment: Sendable, Equatable {
        case steamMissing
        case componentsUnavailable
        case notInstalled
        case installed
        case foreignInjection(String)
    }

    public let deployment: Deployment
    public let runnerVersion: String?
    public let performanceProfilesAvailable: Bool

    public init(
        deployment: Deployment,
        runnerVersion: String? = nil,
        performanceProfilesAvailable: Bool = false
    ) {
        self.deployment = deployment
        self.runnerVersion = runnerVersion
        self.performanceProfilesAvailable = performanceProfilesAvailable
    }

    public static func inspect(
        steamApplication: URL = URL(filePath: "/Applications/Steam.app"),
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam")
    ) -> Self {
        let fm = FileManager.default
        guard fm.fileExists(atPath: steamApplication.path(percentEncoded: false)) else {
            return Self(deployment: .steamMissing)
        }
        guard (try? NativeSteamPayload.bundled()) != nil else {
            return Self(deployment: .componentsUnavailable)
        }

        let plist = steamApplication.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = value as? [String: Any],
              let environment = dictionary["LSEnvironment"] as? [String: Any],
              let insert = environment["DYLD_INSERT_LIBRARIES"] as? String,
              !insert.isEmpty
        else { return Self(deployment: .notInstalled) }

        let expected = steamApplication.appending(path: "Contents/MacOS/\(NativeSteamPayload.dylibName)")
            .path(percentEncoded: false)
        let inserts = insert.split(separator: ":").map(String.init)
        let tools = support.appending(path: "tools")
        let runners = support.appending(path: "runners")
        let toolFields = ((try? String(contentsOf: tools, encoding: .utf8)) ?? "")
            .split(whereSeparator: \Character.isNewline).first?
            .split(separator: "\t", omittingEmptySubsequences: false)
        let runnerVersion = toolFields.flatMap { $0.count > 1 ? String($0[1]) : nil }
        let hasTool = runnerVersion != nil
        let performanceProfilesAvailable: Bool = {
            guard let runnerVersion else { return false }
            let marker = runners.appending(
                path: "crossover-\(runnerVersion)/CrossOver/share/synthehol/performance-capabilities.json"
            )
            guard let data = fm.contents(atPath: marker.path(percentEncoded: false)),
                  let capabilities = try? JSONDecoder().decode(
                    PerformanceRuntimeCapabilities.self, from: data
                  ) else { return false }
            return capabilities.supportsProfileV1
        }()
        if inserts.contains(expected), fm.fileExists(atPath: expected),
           fm.fileExists(atPath: support.appending(path: "deployment.json").path(percentEncoded: false)),
           hasTool, fm.fileExists(atPath: runners.path(percentEncoded: false)),
           NativeSteamBridgeProvisioner.isComplete(at: support.appending(path: "bridge")) {
            return Self(
                deployment: .installed,
                runnerVersion: runnerVersion,
                performanceProfilesAvailable: performanceProfilesAvailable
            )
        }
        if inserts.allSatisfy({ $0 == expected }) {
            return Self(deployment: .notInstalled)
        }
        return Self(deployment: .foreignInjection(insert))
    }
}
