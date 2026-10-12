import Foundation

public struct CustomGame: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var executablePath: String
    public var workingDirectory: String

    public init(
        id: String = UUID().uuidString, name: String,
        executable: URL, workingDirectory: URL
    ) {
        self.id = id
        self.name = name
        executablePath = executable.path(percentEncoded: false)
        self.workingDirectory = workingDirectory.path(percentEncoded: false)
    }
}

public struct CustomGameStore: GameStoreProvider {
    public static let storeID = "custom"
    public static let displayName = "Custom"

    public init() {}

    public func isInstalled(in bottle: Bottle) -> Bool { true }

    public func definitions(in bottle: Bottle) -> [CustomGame] {
        guard let data = FileManager.default.contents(atPath: fileURL(in: bottle).path(percentEncoded: false)),
              let games = try? PropertyListDecoder().decode([CustomGame].self, from: data)
        else { return [] }
        return games
    }

    public func installedGames(in bottle: Bottle) throws -> [InstalledGame] {
        definitions(in: bottle).map { game in
            InstalledGame(
                store: Self.storeID, storeGameID: game.id, name: game.name,
                installPath: game.workingDirectory,
                executablePath: game.executablePath,
                workingDirectory: game.workingDirectory
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func add(
        name: String, executable: URL, workingDirectory: URL, in bottle: Bottle
    ) throws -> CustomGame {
        var games = definitions(in: bottle)
        let game = CustomGame(
            name: name, executable: executable, workingDirectory: workingDirectory
        )
        games.append(game)
        try save(games, in: bottle)
        return game
    }

    public func rename(gameID: String, to name: String, in bottle: Bottle) throws {
        var games = definitions(in: bottle)
        guard let index = games.firstIndex(where: { $0.id == gameID }) else { return }
        games[index].name = name
        try save(games, in: bottle)
    }

    public func remove(gameID: String, in bottle: Bottle) throws {
        var games = definitions(in: bottle)
        games.removeAll { $0.id == gameID }
        try save(games, in: bottle)
    }

    private func fileURL(in bottle: Bottle) -> URL {
        bottle.url.appending(path: "Custom Games.plist")
    }

    private func save(_ games: [CustomGame], in bottle: Bottle) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try (try encoder.encode(games)).write(to: fileURL(in: bottle), options: .atomic)
    }
}
