import Foundation

/// Steam as a `GameStoreProvider`: discovers installed games by reading
/// `steamapps/appmanifest_*.acf` under the bottle's Steam install.
public struct SteamStore: GameStoreProvider {
    public static let storeID = "steam"
    public static let displayName = "Steam"

    /// Support packages Steam installs alongside games that must not appear in
    /// the library (e.g. Steamworks Common Redistributables).
    public static let nonGameAppIDs: Set<Int> = [228980]

    public init() {}

    /// `drive_c/Program Files (x86)/Steam` — Steam's default install location.
    public func steamDirectory(in bottle: Bottle) -> URL {
        bottle.driveC.appending(path: "Program Files (x86)/Steam")
    }

    public func steamExecutable(in bottle: Bottle) -> URL {
        steamDirectory(in: bottle).appending(path: "steam.exe")
    }

    public func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(
            atPath: steamExecutable(in: bottle).path(percentEncoded: false)
        )
    }

    public func installedGames(in bottle: Bottle) throws -> [InstalledGame] {
        let steamappsDirectories = libraryFolders(in: bottle)
        var games: [InstalledGame] = []
        for steamapps in steamappsDirectories {
            let manifests = (try? FileManager.default.contentsOfDirectory(
                at: steamapps, includingPropertiesForKeys: nil
            )) ?? []
            for manifest in manifests
            where manifest.lastPathComponent.hasPrefix("appmanifest_")
                && manifest.pathExtension == "acf" {
                guard let acf = try? String(contentsOf: manifest, encoding: .utf8),
                      let app = SteamApp(acf: acf),
                      app.isFullyInstalled,
                      !Self.nonGameAppIDs.contains(app.appID)
                else { continue }
                games.append(InstalledGame(
                    store: Self.storeID,
                    storeGameID: String(app.appID),
                    name: app.name,
                    posterURL: app.posterURL,
                    installPath: app.installDirectory
                ))
            }
        }
        return games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// All `steamapps/` directories: the default one plus any extra library
    /// folders declared in `libraryfolders.vdf` (paths are Windows-style and
    /// mapped through `drive_c`).
    func libraryFolders(in bottle: Bottle) -> [URL] {
        let defaultSteamapps = steamDirectory(in: bottle).appending(path: "steamapps")
        var folders = [defaultSteamapps]

        let vdfURL = defaultSteamapps.appending(path: "libraryfolders.vdf")
        if let text = try? String(contentsOf: vdfURL, encoding: .utf8),
           let root = try? ValveKeyValues.parse(text),
           case .object(let entries)? = root["libraryfolders"] {
            for (_, entry) in entries {
                guard let windowsPath = entry["path"]?.stringValue else { continue }
                if let mapped = Self.mapWindowsPath(windowsPath, driveC: bottle.driveC) {
                    let steamapps = mapped.appending(path: "steamapps")
                    if steamapps != defaultSteamapps {
                        folders.append(steamapps)
                    }
                }
            }
        }
        return folders.filter {
            FileManager.default.fileExists(atPath: $0.path(percentEncoded: false))
        }
    }

    /// Remote poster candidates, best first (CDN 2×, CDN 1×, wide header).
    public func remoteArtworkCandidates(for game: InstalledGame) -> [URL] {
        let base = "https://steamcdn-a.akamaihd.net/steam/apps/\(game.storeGameID)"
        return [
            URL(string: "\(base)/library_600x900_2x.jpg")!,
            URL(string: "\(base)/library_600x900.jpg")!,
            URL(string: "\(base)/header.jpg")!
        ]
    }

    /// Artwork Steam itself has cached inside the bottle (works offline).
    public func localArtworkFallbacks(for game: InstalledGame, in bottle: Bottle) -> [URL] {
        let cache = steamDirectory(in: bottle)
            .appending(path: "appcache/librarycache/\(game.storeGameID)")
        return [
            cache.appending(path: "library_600x900.jpg"),
            cache.appending(path: "header.jpg")
        ]
    }

    /// Maps `C:\...` to `<bottle>/drive_c/...`. Non-C drives are not mapped (yet).
    static func mapWindowsPath(_ windowsPath: String, driveC: URL) -> URL? {
        let normalized = windowsPath.replacingOccurrences(of: "\\\\", with: "\\")
        guard normalized.lowercased().hasPrefix("c:\\") else { return nil }
        let relative = normalized.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        return driveC.appending(path: relative)
    }
}
