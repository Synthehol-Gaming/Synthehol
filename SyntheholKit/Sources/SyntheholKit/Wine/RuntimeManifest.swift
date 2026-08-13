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
