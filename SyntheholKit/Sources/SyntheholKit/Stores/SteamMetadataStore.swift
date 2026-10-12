import Foundation

/// Store-page metadata for a Steam app, from the storefront `appdetails`
/// endpoint. Unofficial but long-stable and keyless; used for library
/// filtering (genres) and game details.
public struct SteamAppMetadata: Codable, Sendable, Equatable {
    public var genres: [String]
    public var categories: [String]
    public var shortDescription: String
    public var releaseDate: String

    public init(
        genres: [String] = [],
        categories: [String] = [],
        shortDescription: String = "",
        releaseDate: String = ""
    ) {
        self.genres = genres
        self.categories = categories
        self.shortDescription = shortDescription
        self.releaseDate = releaseDate
    }

    /// Steam marks VR-only and VR-capable titles through store categories.
    public var supportsVR: Bool {
        categories.contains { $0.localizedCaseInsensitiveContains("VR") }
    }
}

/// Disk-cached fetcher for `SteamAppMetadata`, one JSON file per appid under
/// `Metadata/`. Long TTL — genres essentially never change — and no negative
/// caching, so a failed fetch retries next launch. Concurrent requests for
/// the same app share one fetch (same pattern as `ArtworkCache`).
public actor SteamMetadataStore {
    private let directory: URL
    private let urlSession: URLSession
    private var memory: [String: SteamAppMetadata] = [:]
    private var inFlight: [String: Task<SteamAppMetadata?, Never>] = [:]

    /// Refetch monthly; store metadata is near-static.
    static let maxCacheAge: TimeInterval = 30 * 86_400

    public init(
        directory: URL = SyntheholPaths.metadata,
        urlSession: URLSession = .shared
    ) {
        self.directory = directory
        self.urlSession = urlSession
    }

    /// Metadata for a Steam appid, from memory → disk → the storefront API.
    /// Returns nil when the app has no store page or the network fails.
    public func metadata(forAppID appID: String) async -> SteamAppMetadata? {
        if let cached = memory[appID] { return cached }
        if let disk = diskCached(appID: appID) {
            memory[appID] = disk
            return disk
        }
        if let existing = inFlight[appID] { return await existing.value }

        let session = urlSession
        let task = Task<SteamAppMetadata?, Never> {
            var components = URLComponents(
                string: "https://store.steampowered.com/api/appdetails"
            )!
            components.queryItems = [
                URLQueryItem(name: "appids", value: appID),
                URLQueryItem(
                    name: "filters",
                    value: "genres,categories,release_date,short_description"
                )
            ]
            guard let (data, response) = try? await session.data(from: components.url!),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            return Self.parse(data, appID: appID)
        }
        inFlight[appID] = task
        let result = await task.value
        inFlight[appID] = nil
        if let result {
            memory[appID] = result
            saveToDisk(result, appID: appID)
        }
        return result
    }

    // MARK: Parsing

    /// `appdetails` response shape: `{"<appid>": {"success": bool, "data": {…}}}`.
    static func parse(_ data: Data, appID: String) -> SteamAppMetadata? {
        struct Entry: Decodable {
            var success: Bool
            var data: Payload?
        }
        struct Payload: Decodable {
            struct IDDescription: Decodable { var description: String }
            struct ReleaseDate: Decodable { var date: String? }
            var genres: [IDDescription]?
            var categories: [IDDescription]?
            var shortDescription: String?
            var releaseDate: ReleaseDate?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let root = try? decoder.decode([String: Entry].self, from: data),
              let entry = root[appID], entry.success, let payload = entry.data
        else { return nil }
        return SteamAppMetadata(
            genres: (payload.genres ?? []).map(\.description),
            categories: (payload.categories ?? []).map(\.description),
            shortDescription: payload.shortDescription ?? "",
            releaseDate: payload.releaseDate?.date ?? ""
        )
    }

    // MARK: Disk cache

    private func cacheFile(appID: String) -> URL {
        directory.appending(path: "\(appID).json")
    }

    private func diskCached(appID: String) -> SteamAppMetadata? {
        let url = cacheFile(appID: appID)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate,
              Date.now.timeIntervalSince(modified) < Self.maxCacheAge,
              let data = FileManager.default.contents(atPath: url.path(percentEncoded: false))
        else { return nil }
        return try? JSONDecoder().decode(SteamAppMetadata.self, from: data)
    }

    private func saveToDisk(_ metadata: SteamAppMetadata, appID: String) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(metadata) {
            try? data.write(to: cacheFile(appID: appID), options: .atomic)
        }
    }
}
