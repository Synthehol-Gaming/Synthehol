import Foundation
import CryptoKit

public struct CompatibilityFixVersion: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var files: [String: String]
    public var wineMetalSHA256: String
}

public struct CompatibilityFix: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var symptom: String
    public var validation: String
    public var source: URL
    public var steamAppIDs: [String]
    public var versions: [CompatibilityFixVersion]
    public var knownGameNames: [String: String] = [:]

    public func recommended(for game: InstalledGame) -> Bool {
        [SteamStore.storeID, NativeSteamStore.storeID].contains(game.store)
            && steamAppIDs.contains(game.storeGameID)
    }
}

/// Recommendations are data only. Discovery never changes a prefix or settings.
public enum CompatibilityFixCatalog {
    public static let fixes: [CompatibilityFix] = [
        CompatibilityFix(
            id: "dxmt-resource-lifetime", title: "DXMT resource lifetime fix",
            symptom: "Game closes during startup with ‘Pure virtual function called’.",
            validation: "Skyrim Special Edition reached its main menu. Gameplay and other games have not been validated. This is an experimental DXMT renderer for 64-bit games; it requires the matching Wine Metal bridge.",
            source: URL(string: "https://github.com/3Shain/dxmt/issues/231")!,
            steamAppIDs: ["489830"], versions: [
                CompatibilityFixVersion(id: "0.80-resource-lifetime.1", files: [
                    "d3d11.dll": "450e66017ddf23087707e432aa34da2fec7c15fa7f1d2b61272ae8d78991831f",
                    "dxgi.dll": "2fa317db052c16bff1f3b188cff8a9a17d9e020722688374173a0c098f080cea",
                    "d3d10core.dll": "77f3eef7d3c01c4341b8eb5b3e26649a137de98e770d67e3f968c0cecd7e1422"
                ], wineMetalSHA256: "bc1a2bc4095eb8297ccaa2a27df1f9703109df5a577139d4fceba7d47f8704e8")
            ], knownGameNames: ["489830": "Skyrim Special Edition"]
        )
    ]

    public static func recommendations(for game: InstalledGame) -> [CompatibilityFix] {
        fixes.filter { $0.recommended(for: game) }
    }
}

public struct CompatibilityFixPackage: Codable, Sendable {
    public var fixID: String
    public var version: String
    public init(fixID: String, version: String) { self.fixID = fixID; self.version = version }
}

public struct AppliedCompatibilityFix: Codable, Sendable, Identifiable {
    public var id: String
    public var fixID: String
    public var version: String
    public var gameID: String
    public var executable: URL
    public var prefix: URL
    public var originalFiles: [String]
    public var originalRegistryValues: [String: String]
}

public enum CompatibilityFixError: Error, LocalizedError {
    case invalidPackage, checksum, incompatibleBridge, invalidExecutable, busy, alreadyApplied, modifiedFiles
    public var errorDescription: String? {
        switch self {
        case .invalidPackage: "This fix package or version is not in the compatibility catalog."
        case .checksum: "The fix package failed SHA-256 verification. Nothing was applied."
        case .incompatibleBridge: "This renderer needs a different Wine Metal bridge. Select a compatible runtime before trying it."
        case .invalidExecutable: "Choose a 64-bit game executable inside this game's installation. Launch the game once to create its prefix first."
        case .busy: "Quit the game and Steam, or stop its configuration, before changing compatibility fixes."
        case .alreadyApplied: "A compatibility fix already manages this executable. Remove it before trying another version."
        case .modifiedFiles: "These files or overrides have changed since the fix was applied. The backup was kept; restore them manually to avoid overwriting your changes."
        }
    }
}

/// Patched versions are imported independently of games. Apply and remove are
/// explicit operations; neither imports nor recommendations activate a fix.
public actor CompatibilityFixStore {
    public let root: URL
    private let catalog: [CompatibilityFix]
    private let fm = FileManager.default

    public init(root: URL = SyntheholPaths.applicationSupport.appending(path: "CompatibilityFixes"),
                catalog: [CompatibilityFix] = CompatibilityFixCatalog.fixes) {
        self.root = root; self.catalog = catalog
    }

    private func descriptor(_ package: CompatibilityFixPackage) throws -> CompatibilityFixVersion {
        guard let fix = catalog.first(where: { $0.id == package.fixID }),
              let version = fix.versions.first(where: { $0.id == package.version }) else {
            throw CompatibilityFixError.invalidPackage
        }
        // Catalog entries cannot escape the managed directory or replace Wine.
        guard !version.files.isEmpty, version.files.keys.allSatisfy({ ["d3d11.dll", "dxgi.dll", "d3d10core.dll"].contains($0) }) else {
            throw CompatibilityFixError.invalidPackage
        }
        return version
    }

    private func packageDirectory(_ package: CompatibilityFixPackage) -> URL {
        root.appending(path: "Versions/\(package.fixID)/\(package.version)")
    }

    public func isImported(_ package: CompatibilityFixPackage) -> Bool {
        guard let version = try? descriptor(package) else { return false }
        return version.files.allSatisfy { hash(packageDirectory(package).appending(path: $0.key)) == $0.value }
    }

    public func importPackage(at directory: URL) throws -> CompatibilityFixPackage {
        let package = try JSONDecoder().decode(CompatibilityFixPackage.self,
            from: Data(contentsOf: directory.appending(path: "FixPackage.json")))
        let version = try descriptor(package)
        for (name, digest) in version.files {
            let file = directory.appending(path: name)
            guard !linked(file), hash(file) == digest else { throw CompatibilityFixError.checksum }
        }
        let target = packageDirectory(package)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = target.deletingLastPathComponent().appending(path: ".import-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        for name in version.files.keys { try fm.copyItem(at: directory.appending(path: name), to: staging.appending(path: name)) }
        for name in ["LICENSE", "COPYING.LIB", "LICENSE.OLD", "SOURCES.json", "Source.zip"] {
            let source = directory.appending(path: name)
            if fm.fileExists(atPath: source.path), !linked(source) {
                try fm.copyItem(at: source, to: staging.appending(path: name))
            }
        }
        try JSONEncoder().encode(package).write(to: staging.appending(path: "FixPackage.json"))
        if fm.fileExists(atPath: target.path) {
            guard isImported(package) else { throw CompatibilityFixError.checksum }
        } else { try fm.moveItem(at: staging, to: target) }
        return package
    }

    public func applications(for game: InstalledGame, prefix: URL) -> [AppliedCompatibilityFix] {
        let folder = root.appending(path: "Applications")
        return ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(AppliedCompatibilityFix.self,
                from: Data(contentsOf: $0.appending(path: "Receipt.json"))) }
            .filter { $0.gameID == game.id && $0.prefix == prefix.standardizedFileURL }
    }

    public func apply(_ package: CompatibilityFixPackage, to game: InstalledGame,
                      executable: URL, prefix: URL) async throws -> AppliedCompatibilityFix {
        let version = try descriptor(package)
        guard isImported(package) else { throw CompatibilityFixError.checksum }
        let executable = executable.standardizedFileURL
        guard let installPath = game.installPath,
              executable.resolvingSymlinksInPath().path.hasPrefix(URL(filePath: installPath).resolvingSymlinksInPath().path + "/"),
              !linked(executable), executable.pathExtension.lowercased() == "exe",
              executable.lastPathComponent.unicodeScalars.allSatisfy({ $0.value >= 32 && !"\\[]\"".unicodeScalars.contains($0) }),
              !["steam.exe", "steamwebhelper.exe"].contains(executable.lastPathComponent.lowercased()),
              is64BitPE(executable), !linked(prefix), fm.fileExists(atPath: prefix.appending(path: "user.reg").path)
        else { throw CompatibilityFixError.invalidExecutable }
        guard hash(prefix.appending(path: "drive_c/windows/system32/winemetal.dll")) == version.wineMetalSHA256 else {
            throw CompatibilityFixError.incompatibleBridge
        }
        try await requireIdle(prefix)
        let identity = digest(Data((prefix.standardizedFileURL.path + "|" + executable.path).utf8))
        let backup = root.appending(path: "Applications/\(identity)")
        guard !fm.fileExists(atPath: backup.path) else { throw CompatibilityFixError.alreadyApplied }
        let receipts = ((try? fm.contentsOfDirectory(at: root.appending(path: "Applications"), includingPropertiesForKeys: nil)) ?? [])
            .compactMap { try? JSONDecoder().decode(AppliedCompatibilityFix.self,
                from: Data(contentsOf: $0.appending(path: "Receipt.json"))) }
        guard !receipts.contains(where: {
            $0.prefix == prefix.standardizedFileURL
                && $0.executable.lastPathComponent.lowercased() == executable.lastPathComponent.lowercased()
        }) else { throw CompatibilityFixError.alreadyApplied }
        let registry = prefix.appending(path: "user.reg")
        guard !linked(registry) else { throw CompatibilityFixError.modifiedFiles }
        let originalRegistry = try String(contentsOf: registry, encoding: .utf8)
        let key = registryKey(executable)
        var originals: [String] = []
        let overrides = registryOverrides(version)
        let previous = registryValues(originalRegistry, key: key, names: Array(overrides.keys))
        // Back up before changing either files or registry. Shared runtime and
        // prefix system DLLs are never replaced; DLLs live beside this game exe.
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        do {
            for name in version.files.keys {
                let target = executable.deletingLastPathComponent().appending(path: name)
                guard !linked(target) else { throw CompatibilityFixError.modifiedFiles }
                if fm.fileExists(atPath: target.path) {
                    try fm.copyItem(at: target, to: backup.appending(path: name)); originals.append(name)
                }
            }
            let receipt = AppliedCompatibilityFix(id: identity, fixID: package.fixID, version: package.version,
                gameID: game.id, executable: executable, prefix: prefix.standardizedFileURL,
                originalFiles: originals, originalRegistryValues: previous)
            try JSONEncoder().encode(receipt).write(to: backup.appending(path: "Receipt.json"), options: .atomic)
            do {
                for name in version.files.keys {
                    try replace(packageDirectory(package).appending(path: name), executable.deletingLastPathComponent().appending(path: name))
                }
                let modified = editRegistry(originalRegistry, key: key, names: Array(overrides.keys), values: overrides)
                try modified.write(to: registry, atomically: true, encoding: .utf8)
            } catch {
                try restoreFiles(receipt, version: version, backup: backup)
                try originalRegistry.write(to: registry, atomically: true, encoding: .utf8)
                try fm.removeItem(at: backup)
                throw error
            }
            return receipt
        } catch {
            // If rollback itself failed, keep its receipt and originals.
            if !fm.fileExists(atPath: backup.appending(path: "Receipt.json").path) { try? fm.removeItem(at: backup) }
            throw error
        }
    }

    public func remove(_ receipt: AppliedCompatibilityFix) async throws {
        guard receipt.id == digest(Data((receipt.prefix.standardizedFileURL.path + "|" + receipt.executable.path).utf8)) else {
            throw CompatibilityFixError.modifiedFiles
        }
        let package = CompatibilityFixPackage(fixID: receipt.fixID, version: receipt.version)
        let version = try descriptor(package)
        try await requireIdle(receipt.prefix)
        let backup = root.appending(path: "Applications/\(receipt.id)")
        let stored = try JSONDecoder().decode(AppliedCompatibilityFix.self,
            from: Data(contentsOf: backup.appending(path: "Receipt.json")))
        guard stored.executable == receipt.executable && stored.prefix == receipt.prefix else { throw CompatibilityFixError.modifiedFiles }
        for (name, expected) in version.files {
            guard hash(receipt.executable.deletingLastPathComponent().appending(path: name)) == expected else { throw CompatibilityFixError.modifiedFiles }
        }
        let registry = receipt.prefix.appending(path: "user.reg")
        guard !linked(registry) else { throw CompatibilityFixError.modifiedFiles }
        let text = try String(contentsOf: registry, encoding: .utf8)
        let overrides = registryOverrides(version)
        guard registryValues(text, key: registryKey(receipt.executable), names: Array(overrides.keys)) == overrides else {
            throw CompatibilityFixError.modifiedFiles
        }
        try restoreFiles(receipt, version: version, backup: backup)
        try editRegistry(text, key: registryKey(receipt.executable), names: Array(overrides.keys), values: receipt.originalRegistryValues)
            .write(to: registry, atomically: true, encoding: .utf8)
        // Retain backups as history; removing the receipt deactivates this entry.
        try fm.removeItem(at: backup.appending(path: "Receipt.json"))
        let history = root.appending(path: "History/\(receipt.id)-\(UUID())")
        try fm.createDirectory(at: history.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: backup, to: history)
    }

    private func requireIdle(_ prefix: URL) async throws {
        let result = try await ProcessRunner.run(executable: URL(filePath: "/usr/sbin/lsof"), arguments: ["-t", "+D", prefix.path])
        guard result.exitCode == 1 && result.standardOutput.isEmpty else { throw CompatibilityFixError.busy }
    }
    private func linked(_ url: URL) -> Bool { (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func hash(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { digest($0) } }
    private func replace(_ source: URL, _ target: URL) throws {
        let temporary = target.deletingLastPathComponent().appending(path: ".fix-\(UUID())")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: source, to: temporary)
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
        else { try fm.moveItem(at: temporary, to: target) }
    }
    private func restoreFiles(_ receipt: AppliedCompatibilityFix, version: CompatibilityFixVersion, backup: URL) throws {
        for name in version.files.keys {
            let target = receipt.executable.deletingLastPathComponent().appending(path: name)
            if receipt.originalFiles.contains(name) { try replace(backup.appending(path: name), target) }
            else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
    }
    private func is64BitPE(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count > 64, data[0] == 0x4d, data[1] == 0x5a else { return false }
        let offset = (0..<4).reduce(0) { $0 | (Int(data[0x3c + $1]) << ($1 * 8)) }
        return offset >= 0 && offset + 6 <= data.count && data[offset..<offset+4] == Data([0x50,0x45,0,0])
            && data[offset+4] == 0x64 && data[offset+5] == 0x86
    }
    private func registryKey(_ executable: URL) -> String {
        let name = executable.lastPathComponent.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "]", with: "\\]")
        return "Software\\\\Wine\\\\AppDefaults\\\\\(name)\\\\DllOverrides"
    }
    private func registryOverrides(_ version: CompatibilityFixVersion) -> [String: String] {
        var result = Dictionary(uniqueKeysWithValues: version.files.keys.map { ($0.replacingOccurrences(of: ".dll", with: ""), "\"native,builtin\"") })
        result["winemetal"] = "\"builtin\""; return result
    }
    private func registryValues(_ text: String, key: String, names: [String]) -> [String: String] {
        var inside = false, result: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("[") { inside = line.lowercased().hasPrefix("[\(key.lowercased())]"); continue }
            if inside {
                for name in names {
                    let prefix = "\"\(name)\"="
                    if line.lowercased().hasPrefix(prefix) { result[name] = String(line.dropFirst(prefix.count)) }
                }
            }
        }
        return result
    }
    private func editRegistry(_ text: String, key: String, names: [String], values: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        let start = lines.firstIndex { $0.lowercased().hasPrefix("[\(key.lowercased())]") }
        if let start {
            let end = lines[(start+1)...].firstIndex { $0.hasPrefix("[") } ?? lines.count
            let body = lines[(start+1)..<end].filter { line in !names.contains { line.lowercased().hasPrefix("\"\($0)\"=") } }
            lines.replaceSubrange((start+1)..<end, with: body + values.sorted { $0.key < $1.key }.map { "\"\($0.key)\"=\($0.value)" } + [""])
        } else {
            lines += ["", "[\(key)]"] + values.sorted { $0.key < $1.key }.map { "\"\($0.key)\"=\($0.value)" } + [""]
        }
        return lines.joined(separator: "\n")
    }
}
