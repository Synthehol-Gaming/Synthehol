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

/// Fetches an account's owned games from the Steam community profile XML —
/// no API key needed, but the profile's game details must not be private.
public struct SteamOwnedGamesFetcher: Sendable {
    public enum FetchError: Error, Equatable {
        /// The profile (or its game details) is private; the XML carries
        /// Steam's message.
        case profileUnavailable(String)
        case requestFailed
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func ownedGames(steamID64: String) async throws -> [OwnedGame] {
        let url = URL(string: "https://steamcommunity.com/profiles/\(steamID64)/games?tab=all&xml=1")!
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
        else { throw FetchError.requestFailed }
        return try Self.parse(xml: data)
    }

    /// Parses the `gamesList` XML. Exposed for testing.
    public static func parse(xml: Data) throws -> [OwnedGame] {
        let parser = GamesXMLParser()
        try parser.run(xml)
        if let error = parser.errorText, parser.games.isEmpty {
            throw FetchError.profileUnavailable(error)
        }
        return parser.games.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private final class GamesXMLParser: NSObject, XMLParserDelegate {
        var games: [OwnedGame] = []
        var errorText: String?

        private var currentElement = ""
        private var currentAppID: Int?
        private var currentName = ""
        private var buffer = ""
        private var insideGame = false

        func run(_ data: Data) throws {
            let parser = XMLParser(data: data)
            parser.delegate = self
            guard parser.parse() || !games.isEmpty || errorText != nil else {
                throw FetchError.requestFailed
            }
        }

        func parser(
            _ parser: XMLParser, didStartElement element: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes: [String: String] = [:]
        ) {
            currentElement = element
            buffer = ""
            if element == "game" {
                insideGame = true
                currentAppID = nil
                currentName = ""
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            buffer += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            buffer += String(data: CDATABlock, encoding: .utf8) ?? ""
        }

        func parser(
            _ parser: XMLParser, didEndElement element: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            switch element {
            case "appID" where insideGame:
                currentAppID = Int(text)
            case "name" where insideGame:
                currentName = text
            case "game":
                insideGame = false
                if let appID = currentAppID, !currentName.isEmpty {
                    games.append(OwnedGame(appID: appID, name: currentName))
                }
            case "error":
                errorText = text
            default:
                break
            }
            buffer = ""
        }
    }
}
