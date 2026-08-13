import CryptoKit
import Foundation

/// Progress through a runtime install.
public enum RuntimeInstallProgress: Sendable, Equatable {
    case downloading(bytesDownloaded: Int64, totalBytes: Int64?)
    case verifying
    case extracting
    case finishing
}

public enum RuntimeStoreError: Error, Equatable {
    /// Downloaded data did not match the manifest's pinned SHA-256. Nothing was installed.
    case checksumMismatch(expected: String, actual: String)
    /// The archive extracted, but the expected Wine binaries were not found in it.
    case invalidArchiveLayout(missing: String)
    case extractionFailed(exitCode: Int32, stderr: String)
    case notInstalled(version: String)
}

/// Downloads, verifies, and installs Wine runtimes under `Runtime/<version>/`.
///
/// Rules (Whisky lessons):
/// - Nothing is installed unless the download's SHA-256 matches the manifest.
/// - Installs are staged in a temporary directory and moved into place atomically.
/// - Old versions are pruned but the previous one is kept for rollback.
public actor RuntimeStore {
    private let rootDirectory: URL
    private let currentLink: URL

    public init(rootDirectory: URL = SyntheholPaths.runtimes) {
        self.rootDirectory = rootDirectory
        self.currentLink = rootDirectory.appending(path: "current")
    }

    // MARK: Queries

    /// Versions installed on disk, sorted newest-last (lexicographic).
    public func installedVersions() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent != "current" && $0.hasDirectoryPath }
            .map(\.lastPathComponent)
            .sorted()
    }

    /// The runtime the `current` symlink points at, if valid.
    public func current() -> WineRuntime? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(
            atPath: currentLink.path(percentEncoded: false)
        ) else { return nil }
        let versionDir = destination.hasPrefix("/")
            ? URL(filePath: destination)
            : rootDirectory.appending(path: destination)
        let runtime = WineRuntime(version: versionDir.lastPathComponent, rootDirectory: versionDir)
        return runtime.isValid ? runtime : nil
    }

    public func runtime(for version: String) throws -> WineRuntime {
        let runtime = WineRuntime(
            version: version,
            rootDirectory: rootDirectory.appending(path: version)
        )
        guard runtime.isValid else { throw RuntimeStoreError.notInstalled(version: version) }
        return runtime
    }

    // MARK: Install

    /// Downloads, verifies, extracts, and activates the runtime described by `manifest`.
    @discardableResult
    public func install(
        _ manifest: RuntimeManifest,
        urlSession: URLSession = .shared,
        onProgress: (@Sendable (RuntimeInstallProgress) -> Void)? = nil
    ) async throws -> WineRuntime {
        let versionDir = rootDirectory.appending(path: manifest.version)
        if let existing = try? runtime(for: manifest.version) {
            try activate(existing)
            return existing
        }

        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let staging = rootDirectory.appending(path: ".staging-\(manifest.version)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Download to the staging dir, hashing as bytes arrive.
        let archive = staging.appending(path: "runtime.tar.gz")
        let actualHash = try await download(
            manifest.url, to: archive, urlSession: urlSession, onProgress: onProgress
        )

        onProgress?(.verifying)
        let expected = manifest.sha256.lowercased()
        guard actualHash == expected else {
            throw RuntimeStoreError.checksumMismatch(expected: expected, actual: actualHash)
        }

        onProgress?(.extracting)
        let extracted = staging.appending(path: "extracted")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let tar = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/tar"),
            arguments: ["-xzf", archive.path(percentEncoded: false),
                        "-C", extracted.path(percentEncoded: false)]
        )
        guard tar.exitCode == 0 else {
            throw RuntimeStoreError.extractionFailed(exitCode: tar.exitCode, stderr: tar.standardError)
        }

        onProgress?(.finishing)
        let candidate = WineRuntime(version: manifest.version, rootDirectory: extracted)
        guard candidate.isValid else {
            throw RuntimeStoreError.invalidArchiveLayout(missing: "Libraries/Wine/bin/wine64")
        }

        try? FileManager.default.removeItem(at: versionDir)
        try FileManager.default.moveItem(at: extracted, to: versionDir)

        let installed = WineRuntime(version: manifest.version, rootDirectory: versionDir)
        try activate(installed)
        try pruneOldVersions(keeping: manifest.version)
        return installed
    }

    /// Points the `current` symlink at `runtime` (relative link, atomic replace).
    public func activate(_ runtime: WineRuntime) throws {
        let temporary = rootDirectory.appending(path: ".current-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            atPath: temporary.path(percentEncoded: false),
            withDestinationPath: runtime.version
        )
        // rename(2) atomically replaces an existing symlink.
        if rename(
            temporary.path(percentEncoded: false),
            currentLink.path(percentEncoded: false)
        ) != 0 {
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Removes installed versions other than the active one and its predecessor.
    private func pruneOldVersions(keeping active: String) throws {
        let versions = installedVersions().filter { $0 != active }
        // Keep the most recent non-active version for rollback.
        for stale in versions.dropLast() {
            try FileManager.default.removeItem(at: rootDirectory.appending(path: stale))
        }
    }

    // MARK: Download

    /// Streams `url` to `destination`, returning the SHA-256 of the bytes written.
    private func download(
        _ url: URL,
        to destination: URL,
        urlSession: URLSession,
        onProgress: (@Sendable (RuntimeInstallProgress) -> Void)?
    ) async throws -> String {
        let (bytes, response) = try await urlSession.bytes(from: url)
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
                // Report roughly every 4 MB.
                if written - lastReport >= 1 << 22 {
                    lastReport = written
                    onProgress?(.downloading(bytesDownloaded: written, totalBytes: totalBytes))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            hasher.update(data: buffer)
            written += Int64(buffer.count)
        }
        onProgress?(.downloading(bytesDownloaded: written, totalBytes: totalBytes))

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
