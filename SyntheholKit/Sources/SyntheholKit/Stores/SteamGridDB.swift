import Foundation

/// Minimal SteamGridDB v2 API client for browsing community game artwork.
/// Requires a (free) personal API key: https://www.steamgriddb.com/profile/preferences/api
public struct SteamGridDBClient: Sendable {
    public enum ClientError: Error, Equatable {
        case unauthorized          // bad/missing API key
        case requestFailed(Int)
    }

    /// A poster ("grid") result: full-size `url` plus a small `thumb`.
    public struct Grid: Decodable, Sendable, Identifiable, Equatable {
        public let id: Int
        public let url: URL
        public let thumb: URL
        public let width: Int
        public let height: Int
    }

    public struct Game: Decodable, Sendable, Identifiable, Equatable {
        public let id: Int
        public let name: String
    }

    struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T
    }

    private let apiKey: String
    private let session: URLSession
    private let baseURL: URL

    public init(
        apiKey: String,
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://www.steamgriddb.com/api/v2")!
    ) {
        self.apiKey = apiKey
        self.session = session
        self.baseURL = baseURL
    }

    /// Posters for a Steam app, portrait 600×900 (our tile aspect).
    public func grids(forSteamAppID appID: String) async throws -> [Grid] {
        try await get("grids/steam/\(appID)", query: [
            URLQueryItem(name: "dimensions", value: "600x900")
        ])
    }

    /// Posters for a SteamGridDB game id (path for non-Steam stores later).
    public func grids(forGameID id: Int) async throws -> [Grid] {
        try await get("grids/game/\(id)", query: [
            URLQueryItem(name: "dimensions", value: "600x900")
        ])
    }

    /// Name search, for games the Steam-appid lookup can't find.
    public func search(_ term: String) async throws -> [Game] {
        let escaped = term.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? term
        return try await get("search/autocomplete/\(escaped)", query: [])
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> T {
        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false
        )!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300:
            return try JSONDecoder().decode(Envelope<T>.self, from: data).data
        case 401, 403:
            throw ClientError.unauthorized
        default:
            throw ClientError.requestFailed(status)
        }
    }
}
