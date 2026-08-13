import CryptoKit
import Foundation

/// Streams a URL to disk, reporting progress and returning the SHA-256 of the
/// bytes written. Shared by the runtime installer (which verifies against a
/// pinned hash) and the Steam installer (which records the hash for logging —
/// Valve's installer changes too often to pin).
public enum FileDownloader {
    /// Downloads `url` to `destination` (replacing it), returning the SHA-256 hex digest.
    @discardableResult
    public static func download(
        _ url: URL,
        to destination: URL,
        urlSession: URLSession = .shared,
        onProgress: (@Sendable (_ bytesDownloaded: Int64, _ totalBytes: Int64?) -> Void)? = nil
    ) async throws -> String {
        let (bytes, response) = try await urlSession.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let totalBytes: Int64? = response.expectedContentLength > 0
            ? response.expectedContentLength : nil

        FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var hasher = SHA256()
        var buffer = Data(capacity: 1 << 16)
        var written: Int64 = 0
        var lastReport: Int64 = 0

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count == 1 << 16 {
                try handle.write(contentsOf: buffer)
                hasher.update(data: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                // Report roughly every 1 MB.
                if written - lastReport >= 1 << 20 {
                    lastReport = written
                    onProgress?(written, totalBytes)
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            written += Int64(buffer.count)
        }
        onProgress?(written, totalBytes)

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
