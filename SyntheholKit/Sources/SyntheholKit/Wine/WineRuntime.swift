import Foundation

/// An installed Wine runtime on disk: `Runtime/<version>/Libraries/…`
///
/// The tarball layout follows the WhiskyWine convention: a top-level `Libraries/`
/// directory containing `Wine/bin/wine64`, `Wine/bin/wineserver`, `DXVK/`, etc.
public struct WineRuntime: Sendable, Equatable {
    public let version: String
    /// `…/Runtime/<version>/`
    public let rootDirectory: URL

    public init(version: String, rootDirectory: URL) {
        self.version = version
        self.rootDirectory = rootDirectory
    }

    public var librariesDirectory: URL { rootDirectory.appending(path: "Libraries") }
    public var wineBinDirectory: URL { librariesDirectory.appending(path: "Wine/bin") }
    public var wine64: URL { wineBinDirectory.appending(path: "wine64") }
    public var wineserver: URL { wineBinDirectory.appending(path: "wineserver") }
    public var dxvkDirectory: URL { librariesDirectory.appending(path: "DXVK") }

    /// True when the essential binaries exist.
    public var isValid: Bool {
        FileManager.default.isExecutableFile(atPath: wine64.path(percentEncoded: false))
            && FileManager.default.isExecutableFile(atPath: wineserver.path(percentEncoded: false))
    }
}

extension RuntimeManifest {
    /// Default stable runtime: the frankea/Whisky community fork's Wine Libraries
    /// v3.1.1 — Wine 11.0, DXVK 1.10.3, DXMT 0.80. SHA-256 as published in the
    /// release notes (verified 2026-08-13).
    ///
    /// A GPTK-capable 4.0 beta lineage exists (CrossOver 25 sources) but publishes
    /// no checksum yet; adopt later by computing and pinning our own, and handle
    /// its `users/crossover` profile-path quirk (see PLAN.md).
    public static let stableDefault = RuntimeManifest(
        version: "3.1.1",
        url: URL(string: "https://github.com/frankea/Whisky/releases/download/v3.1.1/Libraries.tar.gz")!,
        sha256: "01f3a1b43b98065fe20c529c1023b61dd79a6d2ad93bba6040865f646481ccf3",
        notes: "Wine 11.0, DXVK 1.10.3, DXMT 0.80 (frankea/Whisky Wine Libraries v3.1.1)"
    )

    /// Beta channel: Wine 11.15 with CrossOver 26.3 changes, replacing the
    /// broken Wine 10 beta line. Upstream validates both Steam's UI and
    /// D3DMetal. SHA-256 is published with the release.
    public static let gptkBeta = RuntimeManifest(
        version: "4.5.105-beta.1",
        url: URL(string: "https://github.com/frankea/Whisky/releases/download/v4.5.105-beta.1/Libraries.tar.gz")!,
        sha256: "43d78bec577166b5f64b1903f92582e673fbb142ad23921550f77cfeb9ffe0ce",
        notes: "GPTK-capable beta (Wine 11.15 + CrossOver 26.3); validated with Steam UI and D3DMetal"
    )
}
