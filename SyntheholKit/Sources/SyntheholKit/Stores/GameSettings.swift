import Foundation

public enum GamePerformanceProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case compatibility
    case balanced
    case maximumFPS

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .compatibility: "Compatibility"
        case .balanced: "Balanced"
        case .maximumFPS: "Maximum FPS"
        }
    }

    public var detail: String {
        switch self {
        case .compatibility: "Uses the runtime defaults. Best for games with rendering issues."
        case .balanced: "Uses triple buffering and persistent shader caches when the runtime supports them."
        case .maximumFPS: "Also prepares shader variants early and uses parallel compilation to reduce gameplay stutter."
        }
    }

    /// Variables understood by Synthehol's Recall-derived performance runtime.
    /// A stock runtime safely ignores these; the Steam wrapper only applies them
    /// when its runner advertises performance-runtime capabilities.
    public var environment: [String: String] {
        switch self {
        case .compatibility:
            [:]
        case .balanced:
            [
                "DXMT_CANVAS_DRAWABLES": "3",
                "DXMT_USE_DEFAULT_METAL_CACHE": "1"
            ]
        case .maximumFPS:
            [
                "DXMT_CANVAS_DRAWABLES": "3",
                "DXMT_USE_DEFAULT_METAL_CACHE": "1",
                "DXMT_PREPARE_SHADERS": "1",
                "DXMT_CONFIG": "d3d11.releaseShaderIR=True;d3d11.shaderCompilerThreads=8;d3d11.shaderCompilerNormalPriority=True"
            ]
        }
    }
}

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
    public var performanceProfile: GamePerformanceProfile

    public init(
        launchArguments: String = "",
        environment: [String: String] = [:],
        nudgeStuckLoading: Bool = false,
        performanceProfile: GamePerformanceProfile = .compatibility
    ) {
        self.launchArguments = launchArguments
        self.environment = environment
        self.nudgeStuckLoading = nudgeStuckLoading
        self.performanceProfile = performanceProfile
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
        performanceProfile = try container.decodeIfPresent(
            GamePerformanceProfile.self, forKey: .performanceProfile
        ) ?? .compatibility
    }

    /// Arguments split for passing to the launcher (simple whitespace split).
    public var launchArgumentList: [String] {
        launchArguments.split(separator: " ").map(String.init)
    }

    public func effectiveEnvironment(supportsPerformanceProfiles: Bool = true) -> [String: String] {
        guard supportsPerformanceProfiles else { return environment }
        return performanceProfile.environment.merging(environment) { _, explicit in explicit }
    }

    // MARK: Persistence

    static func fileURL(for game: InstalledGame, in bottle: Bottle) -> URL {
        fileURL(for: game, in: bottle.url.appending(path: "Game Settings"))
    }

    public static func fileURL(for game: InstalledGame, in directory: URL) -> URL {
        let safeID = game.id.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return directory.appending(path: "\(safeID).plist")
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
        try save(for: game, in: bottle.url.appending(path: "Game Settings"))
    }

    public static func load(for game: InstalledGame, in directory: URL) -> GameSettings {
        guard let data = FileManager.default.contents(
            atPath: fileURL(for: game, in: directory).path(percentEncoded: false)
        ),
        let settings = try? PropertyListDecoder().decode(GameSettings.self, from: data)
        else { return GameSettings() }
        return settings
    }

    public func save(for game: InstalledGame, in directory: URL) throws {
        let url = Self.fileURL(for: game, in: directory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try (try encoder.encode(self)).write(to: url, options: .atomic)
    }
}

/// Writes the small data file consumed by the native Steam wrapper. The wrapper
/// parses an allow-list and never executes this file as shell code.
public enum NativeSteamPerformanceProfileStore {
    public static func save(
        _ settings: GameSettings,
        appID: String,
        support: URL = SyntheholPaths.applicationSupport.appending(path: "NativeSteam")
    ) throws {
        guard !appID.isEmpty, appID.allSatisfy(\.isNumber) else { return }
        let directory = support.appending(path: "performance-profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let contents = "PROFILE=\(settings.performanceProfile.rawValue)\n"
        try Data(contents.utf8).write(
            to: directory.appending(path: "\(appID).conf"), options: .atomic
        )
    }
}
