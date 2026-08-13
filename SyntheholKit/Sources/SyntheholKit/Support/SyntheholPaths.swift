import Foundation

/// Well-known filesystem locations for Synthehol data.
public enum SyntheholPaths {
    public static let bundleIdentifier = "com.colinobrien.Synthehol"

    /// `~/Library/Application Support/com.colinobrien.Synthehol/`
    public static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: bundleIdentifier)
    }

    /// Installed Wine runtimes, one directory per version (current + previous for rollback).
    public static var runtimes: URL { applicationSupport.appending(path: "Runtime") }

    /// Default location for bottles; individual bottles may live elsewhere.
    public static var bottles: URL { applicationSupport.appending(path: "Bottles") }

    /// Cached game artwork (posters, headers).
    public static var artwork: URL { applicationSupport.appending(path: "Artwork") }

    /// The bottle registry: a plist listing the paths of all known bottles.
    public static var bottleRegistry: URL { applicationSupport.appending(path: "Bottles.plist") }

    /// `~/Library/Logs/com.colinobrien.Synthehol/`
    public static var logs: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs")
            .appending(path: bundleIdentifier)
    }
}
