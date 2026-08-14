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

    /// Beta channel: CrossOver-lineage build (winecx-gptk) that can host
    /// D3DMetal from a user-imported GPTK. SHA-256 computed and pinned from
    /// the published asset on 2026-08-14 (release notes publish no checksum).
    public static let gptkBeta = RuntimeManifest(
        version: "4.0.0-beta.2",
        url: URL(string: "https://github.com/frankea/Whisky/releases/download/v4.0.0-beta.2/Libraries.tar.gz")!,
        sha256: "492b1304172de5d51f8026398a90255ecb99a4fd0409df0bc674fdaad642c2b3",
        notes: "GPTK-capable beta (CrossOver 25 lineage); hosts D3DMetal from a user-imported Game Porting Toolkit"
    )
}
