import Foundation

/// A Steam account that has signed into the bottle's client.
public struct SteamUser: Sendable, Equatable, Identifiable {
    public var steamID64: String
    public var accountName: String
    public var personaName: String
    public var mostRecent: Bool

    public var id: String { steamID64 }
}

extension SteamStore {
    /// Accounts from the bottle's `config/loginusers.vdf` (written by Steam
    /// after sign-in), most-recent first.
    public func loginUsers(in bottle: Bottle) -> [SteamUser] {
        let vdfURL = steamDirectory(in: bottle).appending(path: "config/loginusers.vdf")
        return Self.loginUsers(at: vdfURL)
    }

    static func loginUsers(at vdfURL: URL) -> [SteamUser] {
        guard let text = try? String(contentsOf: vdfURL, encoding: .utf8),
              let root = try? ValveKeyValues.parse(text),
              case .object(let users)? = root["users"]
        else { return [] }
        return users.compactMap { steamID, entry -> SteamUser? in
            guard let accountName = entry["AccountName"]?.stringValue else { return nil }
            return SteamUser(
                steamID64: steamID,
                accountName: accountName,
                personaName: entry["PersonaName"]?.stringValue ?? accountName,
                mostRecent: entry["MostRecent"]?.intValue == 1
            )
        }
        .sorted { $0.mostRecent && !$1.mostRecent }
    }
}

extension NativeSteamStore {
    /// Accounts known to the native macOS Steam client, most-recent first.
    public func loginUsers() -> [SteamUser] {
        SteamStore.loginUsers(at: steamRoot.appending(path: "config/loginusers.vdf"))
    }
}

/// A game the signed-in account owns (installed or not).
public struct OwnedGame: Sendable, Equatable, Identifiable {
    public var appID: Int
    public var name: String

    public var id: Int { appID }

    public init(appID: Int, name: String) {
        self.appID = appID
        self.name = name
    }
}

/// Fetches an account's owned games via the official Steam Web API
/// (`IPlayerService/GetOwnedGames`).
///
/// Requires a free personal API key (https://steamcommunity.com/dev/apikey).
/// Valve removed the old anonymous community-profile XML endpoint (it now
/// redirects to a login page), so a key is the supported path — and unlike the
/// community profile, your own key sees your own library regardless of the
/// profile's privacy settings.
public struct SteamOwnedGamesFetcher: Sendable {
    public enum FetchError: Error, Equatable {
        case invalidKey
        case requestFailed(Int)
    }

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://api.steampowered.com")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    public func ownedGames(steamID64: String) async throws -> [OwnedGame] {
        var components = URLComponents(
            url: baseURL.appending(path: "IPlayerService/GetOwnedGames/v1/"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "steamid", value: steamID64),
            URLQueryItem(name: "include_appinfo", value: "1"),
            URLQueryItem(name: "include_played_free_games", value: "1"),
            URLQueryItem(name: "format", value: "json")
        ]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try Self.parse(json: data)
        case 401, 403:
            throw FetchError.invalidKey
        default:
            throw FetchError.requestFailed(status)
        }
    }

    /// Parses the GetOwnedGames JSON envelope. Exposed for testing.
    static func parse(json: Data) throws -> [OwnedGame] {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let games: [Game]?
            }
            struct Game: Decodable {
                let appid: Int
                let name: String?
            }
            let response: Inner
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: json)
        return (envelope.response.games ?? [])
            .compactMap { game in
                game.name.map { OwnedGame(appID: game.appid, name: $0) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
