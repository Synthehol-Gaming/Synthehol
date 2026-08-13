import Foundation

/// Rosetta 2 detection and installation (required to run x86-64 Windows code).
public enum Rosetta2 {
    private static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    public static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: runtimePath)
    }

    /// Installs Rosetta 2 via `softwareupdate`. macOS shows its own consent UI.
    public static func install() async throws {
        let result = try await ProcessRunner.run(
            executable: URL(filePath: "/usr/sbin/softwareupdate"),
            arguments: ["--install-rosetta", "--agree-to-license"]
        )
        guard result.exitCode == 0 || isInstalled else {
            throw ProcessRunnerError.launchFailed(
                executable: URL(filePath: "/usr/sbin/softwareupdate"),
                underlying: NSError(
                    domain: "Rosetta2", code: Int(result.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: result.standardError]
                )
            )
        }
    }
}
