import Foundation

/// Per-game launch configuration, stored per bottle at
/// `Game Settings/<store>-<gameID>.plist`.
///
/// Keyed by the game's store-qualified ID, never by executable name —
/// Whisky keyed on exe filename and collided when two games shipped
/// `Launch.exe`.
public struct GameSettings: Codable, Equatable, Sendable {
    public var launchArguments: String
    public var environment: [String: String]
    /// Wine-livelock workaround: suspend+resume the game's process a few
    /// times during startup so a stuck loading screen un-wedges itself
    /// (see `GameNudger`).
    public var nudgeStuckLoading: Bool

    public init(
        launchArguments: String = "",
        environment: [String: String] = [:],
        nudgeStuckLoading: Bool = false
    ) {
        self.launchArguments = launchArguments
        self.environment = environment
        self.nudgeStuckLoading = nudgeStuckLoading
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchArguments = try container.decodeIfPresent(String.self, forKey: .launchArguments) ?? ""
        environment = try container.decodeIfPresent(
            [String: String].self, forKey: .environment
        ) ?? [:]
        nudgeStuckLoading = try container.decodeIfPresent(
            Bool.self, forKey: .nudgeStuckLoading
        ) ?? false
    }

    /// Arguments split for passing to the launcher (simple whitespace split).
    public var launchArgumentList: [String] {
        launchArguments.split(separator: " ").map(String.init)
    }

    // MARK: Persistence

    static func fileURL(for game: InstalledGame, in bottle: Bottle) -> URL {
        let safeID = game.id.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return bottle.url.appending(path: "Game Settings/\(safeID).plist")
    }

    public static func load(for game: InstalledGame, in bottle: Bottle) -> GameSettings {
        guard let data = FileManager.default.contents(
            atPath: fileURL(for: game, in: bottle).path(percentEncoded: false)
        ),
        let settings = try? PropertyListDecoder().decode(GameSettings.self, from: data)
        else { return GameSettings() }
        return settings
    }

    public func save(for game: InstalledGame, in bottle: Bottle) throws {
        let url = Self.fileURL(for: game, in: bottle)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try (try encoder.encode(self)).write(to: url, options: .atomic)
    }
}
