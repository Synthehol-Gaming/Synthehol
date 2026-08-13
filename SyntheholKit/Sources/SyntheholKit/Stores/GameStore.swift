import Foundation

/// A game installed in a bottle via some store, identified by `store:gameID`.
/// The library UI, artwork cache, and per-game settings key on `id` — never on a
/// store-specific identifier — so stores beyond Steam (GOG, …) slot in cleanly.
public struct InstalledGame: Sendable, Equatable, Identifiable {
    public var store: String
    public var storeGameID: String
    public var name: String
    public var posterURL: URL?
    public var installPath: String?

    public var id: String { "\(store):\(storeGameID)" }

    public init(
        store: String, storeGameID: String, name: String,
        posterURL: URL? = nil, installPath: String? = nil
    ) {
        self.store = store
        self.storeGameID = storeGameID
        self.name = name
        self.posterURL = posterURL
        self.installPath = installPath
    }
}

/// One conformance per supported game store (Steam first; GOG planned).
public protocol GameStoreProvider: Sendable {
    static var storeID: String { get }
    static var displayName: String { get }

    /// Whether this store's client is installed in the bottle.
    func isInstalled(in bottle: Bottle) -> Bool

    /// Games this store has fully installed in the bottle.
    func installedGames(in bottle: Bottle) throws -> [InstalledGame]
}
