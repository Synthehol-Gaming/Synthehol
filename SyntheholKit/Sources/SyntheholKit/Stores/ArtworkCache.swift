import Foundation

/// Disk cache for game poster artwork (600×900, movie-poster aspect).
///
/// Lookup order: our cache → remote candidates (Steam CDN 2x, then 1x) →
/// local fallbacks (Steam's own librarycache inside the bottle). Successful
/// fetches are cached under `Artwork/<store>-<gameID>.jpg`.
public actor ArtworkCache {
    private let directory: URL
    private let urlSession: URLSession
    private var inFlight: [String: Task<Data?, Never>] = [:]

    public init(
        directory: URL = SyntheholPaths.artwork,
        urlSession: URLSession = .shared
    ) {
        self.directory = directory
        self.urlSession = urlSession
    }

    /// Replaces the cached poster with user-chosen artwork. The cache file is
    /// the single source of truth, so the override survives restarts and is
    /// what launcher-icon export and tiles read.
    public func setCustomPoster(_ data: Data, forGameID id: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: cacheFile(forGameID: id), options: .atomic)
    }

    /// Removes cached/custom artwork; the next `poster` call re-fetches defaults.
    public func resetPoster(forGameID id: String) {
        try? FileManager.default.removeItem(at: cacheFile(forGameID: id))
    }

    func cacheFile(forGameID id: String) -> URL {
        let safeID = id.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safeID).jpg")
    }

    /// Returns poster data for a game, or nil if nothing is available anywhere.
    /// Concurrent requests for the same game share one fetch.
    public func poster(
        for game: InstalledGame,
        remoteCandidates: [URL]? = nil,
        localFallbacks: [URL] = []
    ) async -> Data? {
        let cacheURL = cacheFile(forGameID: game.id)
        if let data = FileManager.default.contents(
            atPath: cacheURL.path(percentEncoded: false)
        ) {
            return data
        }

        if let existing = inFlight[game.id] {
            return await existing.value
        }
        let remotes = remoteCandidates ?? [game.posterURL].compactMap(\.self)
        let session = urlSession
        let task = Task<Data?, Never> {
            for remote in remotes {
                if let (data, response) = try? await session.data(from: remote),
                   (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                   !data.isEmpty {
                    return data
                }
            }
            for fallback in localFallbacks {
                if let data = FileManager.default.contents(
                    atPath: fallback.path(percentEncoded: false)
                ), !data.isEmpty {
                    return data
                }
            }
            return nil
        }
        inFlight[game.id] = task
        let data = await task.value
        inFlight[game.id] = nil

        if let data {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return data
    }
}
