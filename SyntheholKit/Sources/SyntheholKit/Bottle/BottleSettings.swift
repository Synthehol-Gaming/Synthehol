import Foundation

public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
    case win10, win11
}

public enum EnhancedSync: String, Codable, CaseIterable, Sendable {
    case none, esync, msync
}

/// Graphics translation backend used for a bottle (per-game overridable later).
public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case dxmt, d3dMetal, dxvk
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
    public var retinaMode: Bool
    public var dpi: Int?

    public var steamInstalled: Bool

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
        self.retinaMode = true
        self.dpi = nil
        self.steamInstalled = false
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
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? true
        dpi = try c.decodeIfPresent(Int.self, forKey: .dpi)
        steamInstalled = try c.decodeIfPresent(Bool.self, forKey: .steamInstalled) ?? false
    }
}

extension BottleSettings {
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
        if avxEnabled { env["ROSETTA_ADVERTISE_AVX"] = "1" }
        if metalHUD { env["MTL_HUD_ENABLED"] = "1" }
        if graphicsBackend == .dxvk {
            env["WINEDLLOVERRIDES"] = "dxgi,d3d9,d3d10core,d3d11=n,b"
            if dxvkAsync { env["DXVK_ASYNC"] = "1" }
        }
        return env
    }
}
