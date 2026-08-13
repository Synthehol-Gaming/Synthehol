import Foundation

/// The registry of known bottles: a versioned plist holding bottle directory paths.
/// Bottles themselves are self-describing (`Metadata.plist` in the bottle dir), so
/// the registry is only a list — bottles can live anywhere and be re-adopted.
public actor BottleStore {
    private struct Registry: Codable {
        var fileVersion: Int = 1
        var paths: [String] = []
        /// Paths the user explicitly forgot (kept on disk). Auto-discovery must
        /// not resurrect these; `adopt` clears the mark.
        var forgottenPaths: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fileVersion = try c.decodeIfPresent(Int.self, forKey: .fileVersion) ?? 1
            paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
            forgottenPaths = try c.decodeIfPresent([String].self, forKey: .forgottenPaths) ?? []
        }
    }

    private let registryURL: URL
    private let defaultDirectory: URL

    public init(
        registryURL: URL = SyntheholPaths.bottleRegistry,
        defaultDirectory: URL = SyntheholPaths.bottles
    ) {
        self.registryURL = registryURL
        self.defaultDirectory = defaultDirectory
    }

    // MARK: Loading

    /// Loads all registered bottles, sorted by name. Paths whose metadata is
    /// missing are skipped but kept in the registry (external volume may be
    /// ejected — Whisky lesson: don't prune what might come back).
    ///
    /// Also discovers unregistered bottles sitting in the default directory and
    /// adopts them ("lost bottle recovery": survives a deleted registry file and
    /// picks up bottles created by other tools, e.g. the dev CLI).
    public func bottles() -> [Bottle] {
        var registry = loadRegistry()

        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: defaultDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        for candidate in candidates
        where FileManager.default.fileExists(
            atPath: candidate.appending(path: Bottle.metadataFileName).path(percentEncoded: false)
        ) && !registry.paths.contains(where: { pathsEqual($0, candidate) })
            && !registry.forgottenPaths.contains(where: { pathsEqual($0, candidate) }) {
            registry.paths.append(candidate.path(percentEncoded: false))
        }
        try? saveRegistry(registry)

        return registry.paths
            .compactMap { try? Bottle.load(from: URL(filePath: $0)) }
            .sorted {
                $0.settings.name.localizedCaseInsensitiveCompare($1.settings.name) == .orderedAscending
            }
    }

    // MARK: Mutations

    /// Creates a bottle directory + metadata and registers it. The Wine prefix is
    /// initialized separately (`WineExecutor.initializePrefix`) so UI can stage it.
    public func create(name: String, windowsVersion: WindowsVersion = .win10) throws -> Bottle {
        var bottle = try Bottle.create(name: name, in: defaultDirectory)
        bottle.settings.windowsVersion = windowsVersion
        try bottle.saveSettings()
        register(bottle.url)
        return bottle
    }

    /// Registers an existing bottle directory (must contain `Metadata.plist`).
    @discardableResult
    public func adopt(url: URL) throws -> Bottle {
        let bottle = try Bottle.load(from: url)
        register(bottle.url)
        return bottle
    }

    /// Forgets a bottle, optionally deleting its files. Forgotten-but-kept
    /// bottles are remembered so auto-discovery doesn't resurrect them.
    public func remove(_ bottle: Bottle, deleteFiles: Bool) throws {
        var registry = loadRegistry()
        registry.paths.removeAll { pathsEqual($0, bottle.url) }
        if deleteFiles {
            registry.forgottenPaths.removeAll { pathsEqual($0, bottle.url) }
            try saveRegistry(registry)
            try FileManager.default.removeItem(at: bottle.url)
        } else {
            registry.forgottenPaths.append(bottle.url.path(percentEncoded: false))
            try saveRegistry(registry)
        }
    }

    /// Renames a bottle (metadata only — the directory name stays a UUID).
    public func rename(_ bottle: Bottle, to newName: String) throws -> Bottle {
        var updated = bottle
        updated.settings.name = newName
        try updated.saveSettings()
        return updated
    }

    /// Persists modified settings for a registered bottle.
    public func update(_ bottle: Bottle) throws {
        try bottle.saveSettings()
    }

    // MARK: Registry persistence

    private func register(_ url: URL) {
        var registry = loadRegistry()
        registry.forgottenPaths.removeAll { pathsEqual($0, url) }
        if !registry.paths.contains(where: { pathsEqual($0, url) }) {
            registry.paths.append(url.path(percentEncoded: false))
        }
        try? saveRegistry(registry)
    }

    private func loadRegistry() -> Registry {
        guard let data = FileManager.default.contents(
            atPath: registryURL.path(percentEncoded: false)
        ) else { return Registry() }
        return (try? PropertyListDecoder().decode(Registry.self, from: data)) ?? Registry()
    }

    private func saveRegistry(_ registry: Registry) throws {
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .xml
        try (try encoder.encode(registry)).write(to: registryURL, options: .atomic)
    }

    /// Compares paths ignoring trailing slashes (URL(filePath:) adds one for
    /// existing directories) and `/private` symlink standardization.
    private func pathsEqual(_ stored: String, _ url: URL) -> Bool {
        canonical(URL(filePath: stored)) == canonical(url)
    }

    private func canonical(_ url: URL) -> String {
        var path = url.standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
