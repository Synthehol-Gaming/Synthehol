import Foundation

public enum BottleError: Error, Equatable {
    case metadataMissing(URL)
    case alreadyExists(URL)
}

/// A Windows bottle: a directory containing `Metadata.plist` and a Wine prefix.
///
/// Settings are saved explicitly via `saveSettings()` — no `didSet` persistence
/// from arbitrary threads (Whisky lesson).
public struct Bottle: Sendable, Equatable, Identifiable {
    public static let metadataFileName = "Metadata.plist"

    /// The bottle directory (also the WINEPREFIX).
    public let url: URL
    public var settings: BottleSettings

    public var id: String { url.path(percentEncoded: false) }
    public var metadataURL: URL { url.appending(path: Self.metadataFileName) }
    public var driveC: URL { url.appending(path: "drive_c") }

    /// True once Wine has initialized the prefix.
    public var prefixExists: Bool {
        FileManager.default.fileExists(atPath: driveC.path(percentEncoded: false))
    }

    public init(url: URL, settings: BottleSettings) {
        self.url = url
        self.settings = settings
    }

    /// Creates a new bottle directory (named by UUID) and writes its metadata.
    /// The Wine prefix itself is initialized later by `WineExecutor.initializePrefix`.
    public static func create(
        name: String,
        in parent: URL = SyntheholPaths.bottles
    ) throws -> Bottle {
        let directory = parent.appending(path: UUID().uuidString)
        guard !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            throw BottleError.alreadyExists(directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bottle = Bottle(url: directory, settings: BottleSettings(name: name))
        try bottle.saveSettings()
        return bottle
    }

    public static func load(from url: URL) throws -> Bottle {
        let metadataURL = url.appending(path: metadataFileName)
        guard let data = FileManager.default.contents(
            atPath: metadataURL.path(percentEncoded: false)
        ) else {
            throw BottleError.metadataMissing(metadataURL)
        }
        let settings = try PropertyListDecoder().decode(BottleSettings.self, from: data)
        return Bottle(url: url, settings: settings)
    }

    public func saveSettings() throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        let data = try encoder.encode(settings)
        try data.write(to: metadataURL, options: .atomic)
    }
}
