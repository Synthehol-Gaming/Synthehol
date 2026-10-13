import Foundation

/// Synthehol-owned native Steam compatibility components. The directory is
/// populated by our build pipeline from vendored source; no NotProton app or
/// installation is consulted at runtime.
public struct NativeSteamPayload: Sendable {
    public static let dylibName = "synthehol-steamplay.dylib"
    public static let overlayShimName = "synthehol-overlay-shim.dylib"

    public let root: URL
    public let dylib: URL
    public let overlayShim: URL
    public let runScript: URL
    public let iconMaker: URL
    public let signatures: [URL]
    public let bridge: [URL]

    public init(root: URL) throws {
        self.root = root
        dylib = root.appending(path: Self.dylibName)
        overlayShim = root.appending(path: Self.overlayShimName)
        runScript = root.appending(path: "run")
        iconMaker = root.appending(path: "iconmaker")
        let signatureRoot = root.appending(path: "signatures/macos.arm64")
        signatures = ((try? FileManager.default.contentsOfDirectory(
            at: signatureRoot, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let bridgeRoot = root.appending(path: "bridge")
        bridge = [
            "steam.exe", "x86_64-windows-lsteamclient.dll",
            "x86_64-unix-lsteamclient.so", "i386-windows-lsteamclient.dll"
        ].map { bridgeRoot.appending(path: $0) }

        var missing: [String] = []
        for file in [dylib, overlayShim, runScript, iconMaker]
        where !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            missing.append(file.lastPathComponent)
        }
        if signatures.isEmpty { missing.append("signatures/macos.arm64/*.json") }
        for file in bridge
        where !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            missing.append("bridge/\(file.lastPathComponent)")
        }
        guard missing.isEmpty else { throw NativeSteamPayloadError.incomplete(missing) }
    }

    public static func bundled() throws -> Self {
        try bundled(in: .module)
    }

    public static func bundled(in bundle: Bundle) throws -> Self {
        guard let root = bundle.url(forResource: "NativeSteamPayload", withExtension: nil) else {
            throw NativeSteamPayloadError.missing
        }
        return try Self(root: root)
    }
}

public enum NativeSteamPayloadError: Error, LocalizedError, Equatable {
    case missing
    case incomplete([String])

    public var errorDescription: String? {
        switch self {
        case .missing:
            "This build does not contain Synthehol's native Steam components."
        case .incomplete(let files):
            "The native Steam payload is incomplete: \(files.joined(separator: ", "))."
        }
    }
}
