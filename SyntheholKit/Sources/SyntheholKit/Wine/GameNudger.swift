import Foundation

/// Works around a Wine-under-Rosetta livelock that freezes some Unity/Mono
/// games on their loading screen (diagnosed with Core Keeper, Aug 2026): one
/// runtime thread spins forever in a suspend-retry loop (mono-2.0-bdwgc →
/// kernelbase) while every other thread waits on it, so asset loading never
/// finishes. Suspending and resuming the game's whole process (SIGSTOP then
/// SIGCONT) reliably breaks the spin, after which loading completes normally.
///
/// The nudger finds the game's processes by matching their command line
/// against the game's `steamapps/common/<installdir>/` path and nudges them
/// on a fixed early-startup schedule. No stuck-detection is needed: nudging a
/// healthy loading process is a harmless ~1s pause, and the schedule ends
/// long before gameplay.
public enum GameNudger {
    /// Offsets after the game process first appears at which to nudge it.
    /// The observed livelock sets in ~40s into startup (engine init comes
    /// first); the later nudges cover slower machines and cold caches.
    public static let defaultSchedule: [Duration] = [
        .seconds(45), .seconds(90), .seconds(150)
    ]

    /// `pgrep -f` pattern matching processes launched from the game's install
    /// directory (`…\steamapps\common\<installdir>\…`). Matches any path
    /// separator style; nil when the install directory is unknown.
    public static func processPattern(for game: InstalledGame) -> String? {
        guard let directory = game.installPath, !directory.isEmpty else { return nil }
        return "steamapps.common." + NSRegularExpression.escapedPattern(for: directory) + "."
    }

    /// PIDs of running processes whose command line matches the game.
    /// Includes the game's helper processes (crash handlers); suspending
    /// those alongside the game is harmless.
    public static func processIDs(for game: InstalledGame) async -> [pid_t] {
        guard let pattern = processPattern(for: game) else { return [] }
        guard let result = try? await ProcessRunner.run(
            executable: URL(filePath: "/usr/bin/pgrep"),
            arguments: ["-f", pattern]
        ) else { return [] }
        return result.standardOutput.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Suspends and resumes the game's processes once. Returns the number of
    /// processes nudged (0 when the game isn't running).
    @discardableResult
    public static func nudgeNow(
        _ game: InstalledGame,
        onEvent: (@Sendable (String) -> Void)? = nil
    ) async -> Int {
        let pids = await processIDs(for: game)
        guard !pids.isEmpty else { return 0 }
        for pid in pids { kill(pid, SIGSTOP) }
        try? await Task.sleep(for: .seconds(1))
        for pid in pids { kill(pid, SIGCONT) }
        onEvent?("nudged \(game.name) (suspended+resumed pids \(pids.map(String.init).joined(separator: ", ")))")
        return pids.count
    }

    /// Watches for the game's process after launch and nudges it at each
    /// schedule offset. Ends when the schedule completes, the game exits, or
    /// the task is cancelled; give up quietly if no process appears within
    /// three minutes (launch failed or Steam showed a dialog instead).
    public static func startMonitor(
        for game: InstalledGame,
        schedule: [Duration] = defaultSchedule,
        onEvent: (@Sendable (String) -> Void)? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            var appeared = false
            for _ in 0..<60 {
                if Task.isCancelled { return }
                if await !processIDs(for: game).isEmpty { appeared = true; break }
                try? await Task.sleep(for: .seconds(3))
            }
            guard appeared else { return }
            onEvent?("watching \(game.name) for stuck loading")
            var elapsed: Duration = .zero
            for offset in schedule.sorted() {
                try? await Task.sleep(for: offset - elapsed)
                elapsed = offset
                if Task.isCancelled { return }
                if await nudgeNow(game, onEvent: onEvent) == 0 { return }
            }
        }
    }
}
