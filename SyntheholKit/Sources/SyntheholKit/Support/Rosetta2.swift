import Foundation

/// Rosetta 2 detection and installation (required to run x86-64 Windows code).
public enum Rosetta2 {
    private static let runtimePath = "/Library/Apple/usr/libexec/oah/libRosettaRuntime"

    public static var isInstalled: Bool {
        // The file check alone proved unreliable in the wild (Whisky #490 —
        // detection passed but wine died with c0000135); the definitive test
        // is executing an x86_64 binary.
        guard FileManager.default.fileExists(atPath: runtimePath) else { return false }
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
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
