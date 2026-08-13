import Foundation

/// Writes one log file per Wine session to `~/Library/Logs/<bundle-id>/`,
/// with a metadata header. Thread-safe appends (Wine output arrives from
/// pipe-reading threads).
public final class WineLogWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    public let fileURL: URL

    public init?(
        label: String,
        header: [(String, String)] = [],
        directory: URL = SyntheholPaths.logs
    ) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: .now)
            .replacingOccurrences(of: ":", with: "-")
        let safeLabel = label.replacingOccurrences(of: "/", with: "-")
        fileURL = directory.appending(path: "\(stamp) \(safeLabel).log")

        guard fm.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil),
              let handle = try? FileHandle(forWritingTo: fileURL)
        else { return nil }
        self.handle = handle

        var lines = ["Synthehol session log — \(label)", "Date: \(Date.now)"]
        lines += header.map { "\($0.0): \($0.1)" }
        lines.append(String(repeating: "-", count: 40))
        append(lines.joined(separator: "\n"))
    }

    public func append(_ text: String) {
        let line = text.hasSuffix("\n") ? text : text + "\n"
        lock.lock()
        defer { lock.unlock() }
        try? handle.write(contentsOf: Data(line.utf8))
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle.close()
    }

    /// Deletes logs older than `days` (default 7 — Whisky's retention).
    public static func deleteOldLogs(
        olderThanDays days: Int = 7,
        in directory: URL = SyntheholPaths.logs
    ) {
        let fm = FileManager.default
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for entry in entries where entry.pathExtension == "log" {
            let modified = (try? entry.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate) ?? .now
            if modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }
}
