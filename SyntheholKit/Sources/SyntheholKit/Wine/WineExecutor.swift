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
    public func runProgram(
        at executable: URL,
        arguments: [String] = [],
        bottle: Bottle,
        extraEnvironment: [String: String] = [:]
    ) -> AsyncThrowingStream<ProcessEvent, any Error> {
        streamWine(
            ["start", "/unix", executable.path(percentEncoded: false)] + arguments,
            bottle: bottle,
            extraEnvironment: extraEnvironment
        )
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
        if let dpi = bottle.settings.dpi {
            try await addRegistryKey(
                #"HKCU\Control Panel\Desktop"#,
                name: "LogPixels",
                data: String(dpi),
                type: .dword,
                bottle: bottle
            )
        }
    }
}
