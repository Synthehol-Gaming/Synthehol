import Foundation

/// An installed Steam app, parsed from `steamapps/appmanifest_<appid>.acf`.
public struct SteamApp: Equatable, Sendable, Identifiable {
    /// Steam's StateFlags bit for "fully installed".
    public static let stateFullyInstalled = 4

    public var appID: Int
    public var name: String
    public var installDirectory: String
    public var stateFlags: Int
    public var sizeOnDisk: Int64?

    public var id: Int { appID }

    public var isFullyInstalled: Bool {
        stateFlags & Self.stateFullyInstalled != 0
    }

    /// Steam CDN poster artwork (600×900 — movie-poster aspect ratio).
    public var posterURL: URL {
        URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(appID)/library_600x900_2x.jpg")!
    }

    /// Fallback wide-capsule artwork.
    public var headerURL: URL {
        URL(string: "https://steamcdn-a.akamaihd.net/steam/apps/\(appID)/header.jpg")!
    }

    /// Parses an `appmanifest_*.acf` document.
    public init?(acf: String) {
        guard let root = try? ValveKeyValues.parse(acf),
              let state = root["AppState"],
              let appID = state["appid"]?.intValue,
              let name = state["name"]?.stringValue
        else { return nil }

        self.appID = appID
        self.name = name
        self.installDirectory = state["installdir"]?.stringValue ?? ""
        self.stateFlags = state["StateFlags"]?.intValue ?? 0
        self.sizeOnDisk = state["SizeOnDisk"]?.stringValue.flatMap(Int64.init)
    }
}
