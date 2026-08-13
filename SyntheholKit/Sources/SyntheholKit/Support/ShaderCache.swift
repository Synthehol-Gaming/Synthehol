import Foundation

/// D3D shader cache management. The Metal shader caches for D3D translation
/// live under the Darwin user cache dir in `d3dm/`; wiping them fixes some
/// post-update rendering corruption (games rebuild caches on next run).
public enum ShaderCache {
    public static func d3dmCacheDirectory() async -> URL? {
        guard let result = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/getconf"),
            arguments: ["DARWIN_USER_CACHE_DIR"]
        ), result.exitCode == 0 else { return nil }
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(filePath: path).appending(path: "d3dm")
    }

    /// Removes the d3dm cache. Returns whether anything was deleted.
    @discardableResult
    public static func wipe() async -> Bool {
        guard let dir = await d3dmCacheDirectory(),
              FileManager.default.fileExists(atPath: dir.path(percentEncoded: false))
        else { return false }
        return (try? FileManager.default.removeItem(at: dir)) != nil
    }
}
