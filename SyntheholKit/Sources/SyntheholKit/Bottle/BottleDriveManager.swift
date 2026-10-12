import Foundation

public enum BottleDriveError: LocalizedError {
    case invalidLetters
    case letterInUse(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLetters:
            "Drive letters must be unique and between D: and Y:."
        case .letterInUse(let letter):
            "Drive \(letter.uppercased()): is already in use by Wine or a mounted volume. Choose another drive letter."
        }
    }
}

public enum BottleDriveManager {
    public static let availableLetters = (Unicode.Scalar("D").value...Unicode.Scalar("Y").value)
        .compactMap(Unicode.Scalar.init)
        .map(String.init)

    /// Reconciles Wine's `dosdevices` symlinks with the mappings stored in the
    /// configuration. Host folders are only linked; Synthehol never modifies
    /// or takes ownership of them.
    public static func apply(
        previous: [BottleDrive], current: [BottleDrive], to bottle: Bottle
    ) throws {
        let normalized = current.map { $0.letter.uppercased() }
        guard Set(normalized).count == normalized.count,
              normalized.allSatisfy(availableLetters.contains)
        else { throw BottleDriveError.invalidLetters }

        let fileManager = FileManager.default
        let dosDevices = bottle.url.appending(path: "dosdevices", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: dosDevices, withIntermediateDirectories: true)

        let currentByLetter = Dictionary(uniqueKeysWithValues: current.map { ($0.letter.uppercased(), $0) })
        for old in previous where currentByLetter[old.letter.uppercased()] != old {
            let link = driveLink(old.letter, in: dosDevices)
            if isSymbolicLink(link) { try? fileManager.removeItem(at: link) }
        }

        for drive in current {
            let link = driveLink(drive.letter, in: dosDevices)
            let desired = drive.url.path(percentEncoded: false)
            if let existing = try? fileManager.destinationOfSymbolicLink(
                atPath: link.path(percentEncoded: false)
            ), existing == desired {
                continue
            }
            if fileManager.fileExists(atPath: link.path(percentEncoded: false)) || isSymbolicLink(link) {
                // Only replace a letter that was already managed by this setting.
                guard previous.contains(where: { $0.letter.caseInsensitiveCompare(drive.letter) == .orderedSame })
                else { throw BottleDriveError.letterInUse(drive.letter) }
                try fileManager.removeItem(at: link)
            }
            try fileManager.createSymbolicLink(atPath: link.path(percentEncoded: false), withDestinationPath: desired)
        }
    }

    /// Drive letters Wine already owns (including automatically mounted
    /// volumes). Device links such as `d::` are deliberately ignored; the
    /// corresponding `d:` filesystem link is what makes a letter unavailable.
    public static func occupiedLetters(in bottle: Bottle) -> Set<String> {
        let dosDevices = bottle.url.appending(path: "dosdevices", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dosDevices.path(percentEncoded: false))) ?? []
        return Set(names.compactMap { name in
            guard name.count == 2, name.last == ":",
                  let letter = name.first.map(String.init)?.uppercased(),
                  availableLetters.contains(letter)
            else { return nil }
            return letter
        })
    }

    private static func driveLink(_ letter: String, in directory: URL) -> URL {
        // `URL.appending(path:)` treats the colon as URL syntax on some SDKs;
        // Wine requires the literal filename `d:`.
        URL(
            fileURLWithPath: directory.path(percentEncoded: false) + "/\(letter.lowercased()):",
            isDirectory: false
        )
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
