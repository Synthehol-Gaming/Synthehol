import Foundation

/// Runs Wine tools from a specific runtime against a specific bottle.
public struct WineExecutor: Sendable {
    public let runtime: WineRuntime

    public init(runtime: WineRuntime) {
        self.runtime = runtime
    }

    // MARK: Environment

    /// Full child environment for a Wine invocation: base Wine variables plus the
    /// bottle's settings-derived variables plus per-call extras (highest priority).
    public func environment(
        for bottle: Bottle,
        extra: [String: String] = [:]
    ) -> [String: String] {
        var env: [String: String] = [
            "WINEPREFIX": bottle.url.path(percentEncoded: false),
            "WINEDEBUG": "fixme-all",
            "GST_DEBUG": "1"
        ]
        env.merge(bottle.settings.wineEnvironment()) { _, new in new }
        env.merge(extra) { _, new in new }
        return env
    }

    // MARK: Wine invocations

    /// Runs `wine64 <args>` to completion.
    @discardableResult
    public func runWine(
        _ arguments: [String],
        bottle: Bottle,
        extraEnvironment: [String: String] = [:]
    ) async throws -> ProcessResult {
        try await ProcessRunner.run(
            executable: runtime.wine64,
            arguments: arguments,
            environment: environment(for: bottle, extra: extraEnvironment)
        )
    }

    /// Streams `wine64 <args>` output (for long-running programs and logging).
    public func streamWine(
        _ arguments: [String],
        bottle: Bottle,
        extraEnvironment: [String: String] = [:]
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        ProcessRunner.stream(
            executable: runtime.wine64,
            arguments: arguments,
            environment: environment(for: bottle, extra: extraEnvironment)
        )
    }

    /// Initializes the bottle's Wine prefix and sets its Windows version.
    /// `winecfg -v <version>` both creates the prefix (first run) and configures it.
    public func initializePrefix(for bottle: Bottle) async throws {
        try await runWine(
            ["winecfg", "-v", bottle.settings.windowsVersion.rawValue],
            bottle: bottle
        )
    }

    /// Launches a Windows executable: `wine64 start /unix <path> <args>`.
    /// With `waitForExit`, the stream stays open until the program exits
    /// (`start /wait`), enabling exit-triggered cleanup.
    public func runProgram(
        at executable: URL,
        arguments: [String] = [],
        bottle: Bottle,
        waitForExit: Bool = false,
        extraEnvironment: [String: String] = [:]
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        let startArguments = ["start"]
            + (waitForExit ? ["/wait"] : [])
            + ["/unix", executable.path(percentEncoded: false)]
        return streamWine(
            startArguments + arguments,
            bottle: bottle,
            extraEnvironment: extraEnvironment
        )
    }

    /// Whether any process with this image name (e.g. `steam.exe`) is running
    /// in the bottle, per Wine's tasklist.
    public func isProcessRunning(imageName: String, bottle: Bottle) async -> Bool {
        let result = try? await runWine(["tasklist"], bottle: bottle)
        return result?.standardOutput.localizedCaseInsensitiveContains(imageName) ?? false
    }

    /// `wine --version`, e.g. `wine-11.0`.
    public func wineVersion() async throws -> String {
        let result = try await ProcessRunner.run(
            executable: runtime.wine64,
            arguments: ["--version"]
        )
        var version = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if version.hasPrefix("wine-") { version.removeFirst("wine-".count) }
        return version
    }

    /// Shuts down all Wine processes in the bottle (`wineserver -k`).
    public func killBottle(_ bottle: Bottle) async throws {
        _ = try await ProcessRunner.run(
            executable: runtime.wineserver,
            arguments: ["-k"],
            environment: ["WINEPREFIX": bottle.url.path(percentEncoded: false)]
        )
    }

    // MARK: Registry

    public enum RegistryType: String, Sendable {
        case binary = "REG_BINARY"
        case dword = "REG_DWORD"
        case qword = "REG_QWORD"
        case string = "REG_SZ"
    }

    public func addRegistryKey(
        _ key: String, name: String, data: String, type: RegistryType, bottle: Bottle
    ) async throws {
        try await runWine(
            ["reg", "add", key, "-v", name, "-t", type.rawValue, "-d", data, "-f"],
            bottle: bottle
        )
    }

    /// Changes the prefix's Windows version and keeps the registry build number
    /// consistent with it.
    public func changeWindowsVersion(_ version: WindowsVersion, bottle: Bottle) async throws {
        try await runWine(["winecfg", "-v", version.rawValue], bottle: bottle)
        let key = #"HKLM\Software\Microsoft\Windows NT\CurrentVersion"#
        try await addRegistryKey(
            key, name: "CurrentBuild", data: version.buildNumber, type: .string, bottle: bottle
        )
        try await addRegistryKey(
            key, name: "CurrentBuildNumber", data: version.buildNumber, type: .string, bottle: bottle
        )
    }

    /// Wine's built-in GUI tools, used from the bottle configuration UI.
    public enum WineTool: String, Sendable, CaseIterable {
        case winecfg
        case controlPanel = "control"
        case regedit
        case taskManager = "taskmgr"
        case explorer

        public var displayName: String {
            switch self {
            case .winecfg: "Wine Configuration"
            case .controlPanel: "Control Panel"
            case .regedit: "Registry Editor"
            case .taskManager: "Task Manager"
            case .explorer: "File Explorer"
            }
        }
    }

    /// Launches a Wine GUI tool without waiting for it to exit. Output is
    /// drained in a detached task so the pipe never blocks the tool.
    public func launchTool(_ tool: WineTool, bottle: Bottle) {
        let stream = streamWine([tool.rawValue], bottle: bottle)
        Task.detached(priority: .utility) {
            for try await _ in stream {}
        }
    }

    /// Applies settings that live in the registry rather than the environment
    /// (retina mode, DPI). Call after prefix initialization or settings changes.
    public func applyRegistrySettings(for bottle: Bottle) async throws {
        try await addRegistryKey(
            #"HKCU\Software\Wine\Mac Driver"#,
            name: "RetinaMode",
            data: bottle.settings.retinaMode ? "y" : "n",
            type: .string,
            bottle: bottle
        )
        // Always written: Retina Mode without a matching DPI renders half-size.
        try await addRegistryKey(
            #"HKCU\Control Panel\Desktop"#,
            name: "LogPixels",
            data: String(bottle.settings.effectiveDPI),
            type: .dword,
            bottle: bottle
        )
        // Fullscreen display capture for correct cursor confinement in games.
        try await addRegistryKey(
            #"HKCU\Software\Wine\Mac Driver"#,
            name: "CaptureDisplaysForFullscreen",
            data: bottle.settings.captureDisplaysForFullscreen ? "y" : "n",
            type: .string,
            bottle: bottle
        )
    }
}
