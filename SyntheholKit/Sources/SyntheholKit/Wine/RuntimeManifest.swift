import Foundation

/// Describes a downloadable Wine runtime build.
///
/// Shipped in-app and overridable from a remote endpoint so the runtime source can
/// change without an app release. Downloads are verified against `sha256` before
/// install — never installed unverified (Whisky lesson).
public struct RuntimeManifest: Codable, Equatable, Sendable {
    public var version: String
    public var url: URL
    public var sha256: String
    public var notes: String?

    public init(version: String, url: URL, sha256: String, notes: String? = nil) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.notes = notes
    }

    /// Install location for this runtime version.
    public var installDirectory: URL {
        SyntheholPaths.runtimes.appending(path: version)
    }
}

/// Sidecar emitted with a locally assembled runtime. The archive path is
/// resolved relative to the sidecar, while the archive bytes remain subject to
/// the same SHA-256 verification as a downloaded runtime.
public struct LocalRuntimeManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var version: String
    public var archive: String
    public var sha256: String

    public init(schemaVersion: Int = 1, version: String, archive: String, sha256: String) {
        self.schemaVersion = schemaVersion
        self.version = version
        self.archive = archive
        self.sha256 = sha256
    }

    public static func load(from url: URL) throws -> LocalRuntimeManifest {
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard value.schemaVersion == 1 else {
            throw RuntimeStoreError.invalidLocalManifest
        }
        return value
    }

    public func runtimeManifest(relativeTo sidecar: URL) throws -> RuntimeManifest {
        guard !archive.isEmpty, URL(filePath: archive).lastPathComponent == archive else {
            throw RuntimeStoreError.invalidLocalManifest
        }
        return RuntimeManifest(
            version: version,
            url: sidecar.deletingLastPathComponent().appending(path: archive),
            sha256: sha256,
            notes: "Locally assembled performance runtime"
        )
    }
}
