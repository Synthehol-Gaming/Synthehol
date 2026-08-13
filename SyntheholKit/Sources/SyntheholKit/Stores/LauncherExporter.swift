import Foundation

/// Exports a per-game launcher `.app`.
///
/// The launcher is a tiny shell that opens a `synthehol://launch` URL, so the
/// actual launch always goes through Synthehol's normal pipeline (fresh Wine
/// environment, exit monitoring, cleanup) instead of a frozen copy of the wine
/// invocation — Whisky baked the full env into the script, which went stale
/// whenever settings changed.
public enum LauncherExporter {
    /// Default export location: `~/Applications/Synthehol/`.
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/Synthehol")
    }

    /// Builds the `synthehol://launch` URL a launcher opens.
    public static func launchURL(for game: InstalledGame, in bottle: Bottle) -> URL {
        var components = URLComponents()
        components.scheme = "synthehol"
        components.host = "launch"
        components.queryItems = [
            URLQueryItem(name: "bottle", value: bottle.url.path(percentEncoded: false)),
            URLQueryItem(name: "store", value: game.store),
            URLQueryItem(name: "game", value: game.storeGameID)
        ]
        return components.url!
    }

    /// Creates (or replaces) `<Game Name>.app` in `directory` and returns its URL.
    @discardableResult
    public static func export(
        game: InstalledGame,
        bottle: Bottle,
        to directory: URL = defaultDirectory
    ) throws -> URL {
        let fm = FileManager.default
        let safeName = game.name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        let appURL = directory.appending(path: "\(safeName).app")
        let contents = appURL.appending(path: "Contents")
        let macOS = contents.appending(path: "MacOS")

        try? fm.removeItem(at: appURL)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)

        let identifierSuffix = game.id.replacingOccurrences(of: ":", with: "-")
        let infoPlist: [String: Any] = [
            "CFBundleName": game.name,
            "CFBundleDisplayName": game.name,
            "CFBundleIdentifier": "com.colinobrien.Synthehol.launcher.\(identifierSuffix)",
            "CFBundleExecutable": "launch",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "15.0",
            // Game Mode / App Store category semantics for game launchers.
            "LSApplicationCategoryType": "public.app-category.games"
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoPlist, format: .xml, options: 0
        )
        try plistData.write(to: contents.appending(path: "Info.plist"))

        let url = launchURL(for: game, in: bottle)
        let script = """
        #!/bin/sh
        exec /usr/bin/open "\(url.absoluteString)"
        """
        let scriptURL = macOS.appending(path: "launch")
        try Data(script.utf8).write(to: scriptURL)
        try fm.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path(percentEncoded: false)
        )
        return appURL
    }
}
