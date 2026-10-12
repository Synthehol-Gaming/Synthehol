import CryptoKit
import Foundation

/// Copies the Valve-owned Steam client DLLs needed by the native-Steam bridge
/// from a Windows Steam installation that the user created in Synthehol.
public enum NativeSteamBridgeProvisioner {
    public static let requiredFiles = [
        "steamclient64.dll": UInt16(0x8664),
        "steamclient.dll": UInt16(0x014c),
        "tier0_s64.dll": UInt16(0x8664),
        "vstdlib_s64.dll": UInt16(0x8664),
    ]

    public struct Record: Codable, Sendable, Equatable {
        public let sourceBottle: String
        public let installedAt: Date
        public let sha256: [String: String]
    }

    public static func provision(from bottles: [Bottle], into bridge: URL) throws {
        guard let source = bottles.lazy
            .map({ ($0, steamDirectory(in: $0)) })
            .first(where: { candidateIsComplete(at: $0.1) })
        else { throw NativeSteamBridgeError.steamConfigurationRequired }

        let fm = FileManager.default
        try fm.createDirectory(at: bridge, withIntermediateDirectories: true)
        var hashes: [String: String] = [:]
        for name in requiredFiles.keys.sorted() {
            let input = source.1.appending(path: name)
            let data = try Data(contentsOf: input, options: .mappedIfSafe)
            hashes[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try replace(input, at: bridge.appending(path: name))
        }
        let record = Record(
            sourceBottle: source.0.id, installedAt: .now, sha256: hashes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(
            to: bridge.appending(path: "valve-components.json"), options: .atomic
        )
    }

    public static func isComplete(at bridge: URL) -> Bool {
        candidateIsComplete(at: bridge)
    }

    private static func steamDirectory(in bottle: Bottle) -> URL {
        bottle.driveC.appending(path: "Program Files (x86)/Steam")
    }

    private static func candidateIsComplete(at directory: URL) -> Bool {
        requiredFiles.allSatisfy { name, machine in
            isPE(directory.appending(path: name), machine: machine)
        }
    }

    private static func isPE(_ url: URL, machine: UInt16) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 64), header.count >= 64,
              header[0] == 0x4d, header[1] == 0x5a else { return false }
        let offset = header[0x3c..<0x40].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        guard offset <= 16 * 1_024 * 1_024 else { return false }
        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let pe = try handle.read(upToCount: 6), pe.count == 6,
                  Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return false }
            return UInt16(pe[4]) | (UInt16(pe[5]) << 8) == machine
        } catch { return false }
    }

    private static func replace(_ source: URL, at destination: URL) throws {
        let fm = FileManager.default
        let staging = destination.appendingPathExtension("new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}

public enum NativeSteamBridgeError: Error, LocalizedError {
    case steamConfigurationRequired

    public var errorDescription: String? {
        "Create at least one Synthehol configuration and install Steam in it, then install Synthehol Steam Play again. The compatibility bridge needs Valve files from that Steam installation."
    }
}
