import Foundation

public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win10, win11

    public var displayName: String {
        switch self {
        case .win10: "Windows 10"
        case .win11: "Windows 11"
        }
    }

    /// Compact form for generated configuration names ("Steam on Win11").
    public var shortName: String {
        switch self {
        case .win10: "Win10"
        case .win11: "Win11"
        }
    }

    /// Build number written to the registry alongside `winecfg -v` so version
    /// checks that read CurrentBuild(Number) see a consistent Windows.
    public var buildNumber: String {
        switch self {
        case .win10: "19045"
        case .win11: "22621"
        }
    }
}

public enum EnhancedSync: String, Codable, CaseIterable, Sendable {
    case none, esync, msync
}

/// Graphics translation backend used for a bottle (per-game overridable later).
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case dxmt
    case d3dMetal = "d3dmetal"
    case dxvk
}

public struct BottleDrive: Codable, Equatable, Identifiable, Sendable {
    public var letter: String
    public var path: String

    public init(letter: String, url: URL) {
        self.letter = letter.uppercased()
        path = url.path(percentEncoded: false)
    }

    public var id: String { letter.uppercased() }
    public var url: URL { URL(filePath: path, directoryHint: .isDirectory) }
}

/// Per-bottle configuration, persisted as `Metadata.plist` in the bottle directory.
///
/// `fileVersion` gates additive migrations. Unlike Whisky, a version or runtime
/// mismatch must never reset settings — decode leniently and migrate forward.
public struct BottleSettings: Codable, Equatable, Sendable {
    public static let currentFileVersion = 1

    public var fileVersion: Int
    public var name: String
    public var created: Date

    public var runtimeVersion: String?
    public var windowsVersion: WindowsVersion
    public var enhancedSync: EnhancedSync
    public var avxEnabled: Bool

    public var graphicsBackend: GraphicsBackend
    public var metalHUD: Bool
    public var dxvkAsync: Bool
    /// Fullscreen games capture the display (Mac driver
    /// `CaptureDisplaysForFullscreen`): proper cursor confinement/hiding and
    /// lower compositing overhead, at the cost of slightly clunkier Cmd+Tab
    /// while a captured fullscreen game runs. Wine defaults this off; games
    /// want it on.
    public var captureDisplaysForFullscreen: Bool
    public var retinaMode: Bool
    /// Explicit Windows DPI (LogPixels). `nil` = automatic: 192 when Retina Mode
    /// is on (2× scaling so UI is crisp *and* correctly sized on Retina
    /// displays — with the Windows default of 96 everything renders half-size),
    /// 96 otherwise.
    public var dpi: Int?
    public var drives: [BottleDrive]

    public var steamInstalled: Bool
    /// Identifier of a shared Steam Web API key profile. The secret itself is
    /// stored once in app preferences so multiple bottles can select it.
    public var steamWebAPIKeyID: String?

    public init(name: String, created: Date = .now) {
        self.fileVersion = Self.currentFileVersion
        self.name = name
        self.created = created
        self.runtimeVersion = nil
        self.windowsVersion = .win10
        self.enhancedSync = .msync
        self.avxEnabled = false
        self.graphicsBackend = .dxmt
        self.metalHUD = false
        self.dxvkAsync = true
        self.captureDisplaysForFullscreen = true
        self.retinaMode = true
        self.dpi = nil
        self.drives = []
        self.steamInstalled = false
        self.steamWebAPIKeyID = nil
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileVersion = try c.decodeIfPresent(Int.self, forKey: .fileVersion) ?? 1
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Bottle"
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? .now
        runtimeVersion = try c.decodeIfPresent(String.self, forKey: .runtimeVersion)
        windowsVersion = try c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion) ?? .win10
        enhancedSync = try c.decodeIfPresent(EnhancedSync.self, forKey: .enhancedSync) ?? .msync
        avxEnabled = try c.decodeIfPresent(Bool.self, forKey: .avxEnabled) ?? false
        graphicsBackend = try c.decodeIfPresent(GraphicsBackend.self, forKey: .graphicsBackend) ?? .dxmt
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? false
        dxvkAsync = try c.decodeIfPresent(Bool.self, forKey: .dxvkAsync) ?? true
        captureDisplaysForFullscreen = try c.decodeIfPresent(
            Bool.self, forKey: .captureDisplaysForFullscreen
        ) ?? true
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        drives = try c.decodeIfPresent([BottleDrive].self, forKey: .drives) ?? []
        steamInstalled = try c.decodeIfPresent(Bool.self, forKey: .steamInstalled) ?? false
        steamWebAPIKeyID = try c.decodeIfPresent(String.self, forKey: .steamWebAPIKeyID)
    }
}

extension BottleSettings {
    /// The DPI actually written to the prefix (see `dpi`).
    public var effectiveDPI: Int {
        dpi ?? (retinaMode ? 192 : 96)
    }

    /// Wine environment variables implied by these settings.
    ///
    /// Note: msync must also advertise ESYNC — D3DMetal detects ESYNC and changes
    /// behavior; without the flag it breaks under msync (hardcoded in libd3dshared).
    public func wineEnvironment() -> [String: String] {
        var env: [String: String] = [:]
        switch enhancedSync {
        case .none:
            break
        case .esync:
            env["WINEESYNC"] = "1"
        case .msync:
            env["WINEMSYNC"] = "1"
            env["WINEESYNC"] = "1"
        }
        // D3DMetal itself uses AVX and fails device creation without it
        // advertised (Apple's own GPTK launcher always sets this).
        if avxEnabled || graphicsBackend == .d3dMetal {
            env["ROSETTA_ADVERTISE_AVX"] = "1"
        }
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if let overrides = GraphicsBackendDeployer.dllOverrides(for: graphicsBackend) {
            env["WINEDLLOVERRIDES"] = overrides
        }
        if graphicsBackend == .dxvk, dxvkAsync {
            env["DXVK_ASYNC"] = "1"
        }
        return env
    }
}
