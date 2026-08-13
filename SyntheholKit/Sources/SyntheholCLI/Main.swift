import Foundation
import SyntheholKit

/// Development CLI harness for SyntheholKit (Phase 1 acceptance tool).
/// Not shipped to users; exercises runtime install, bottle creation, and Wine.
@main
struct Main {
    static let usage = """
    synthehol-dev — SyntheholKit development harness

    USAGE:
      synthehol-dev runtime install        Download, verify, install the default runtime
      synthehol-dev runtime list           List installed runtime versions
      synthehol-dev rosetta                Check Rosetta 2 status
      synthehol-dev bottle create <name>   Create a bottle and initialize its prefix
      synthehol-dev bottle list            List bottles in the default location
      synthehol-dev winecfg <bottle-path>  Open winecfg for a bottle
      synthehol-dev wine <bottle-path> <args...>   Run wine64 with arguments
      synthehol-dev games <bottle-path>    List installed Steam games in a bottle
      synthehol-dev steam install <bottle-path>   Install the Steam client into a bottle
      synthehol-dev steam launch <bottle-path>    Launch the Steam client in a bottle
    """

    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await run(args)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }
    }

    static func run(_ args: [String]) async throws {
        switch args.first {
        case "runtime" where args.count >= 2 && args[1] == "install":
            try await installRuntime()
        case "runtime" where args.count >= 2 && args[1] == "list":
            let store = RuntimeStore()
            let current = await store.current()
            for version in await store.installedVersions() {
                let marker = version == current?.version ? " (current)" : ""
                print("\(version)\(marker)")
            }
        case "rosetta":
            print(Rosetta2.isInstalled ? "Rosetta 2: installed" : "Rosetta 2: NOT installed")
        case "bottle" where args.count >= 3 && args[1] == "create":
            try await createBottle(named: args[2])
        case "bottle" where args.count >= 2 && args[1] == "list":
            for bottle in await BottleStore().bottles() {
                print("\(bottle.settings.name)\t\(bottle.url.path(percentEncoded: false))")
            }
        case "winecfg" where args.count >= 2:
            let bottle = try Bottle.load(from: URL(filePath: args[1]))
            let executor = try await currentExecutor()
            try await executor.runWine(["winecfg"], bottle: bottle)
        case "wine" where args.count >= 3:
            let bottle = try Bottle.load(from: URL(filePath: args[1]))
            let executor = try await currentExecutor()
            let result = try await executor.runWine(Array(args.dropFirst(2)), bottle: bottle)
            print(result.standardOutput)
            if !result.standardError.isEmpty { fputs(result.standardError, stderr) }
        case "steam" where args.count >= 3 && args[1] == "install":
            let bottle = try Bottle.load(from: URL(filePath: args[2]))
            let executor = try await currentExecutor()
            print("Installing Steam into \"\(bottle.settings.name)\"…")
            let updated = try await SteamInstaller().install(in: bottle, executor: executor) { progress in
                switch progress {
                case .downloading(let done, _):
                    print("\rdownloading installer: \(done / 1024) KB", terminator: "")
                    fflush(stdout)
                case .installing: print("\nrunning silent install…")
                case .verifying: print("verifying…")
                }
            }
            print("Steam installed at \(SteamStore().steamExecutable(in: updated).path(percentEncoded: false))")
        case "steam" where args.count >= 3 && args[1] == "launch":
            let bottle = try Bottle.load(from: URL(filePath: args[2]))
            let executor = try await currentExecutor()
            let monitor = SteamInstaller().launch(in: bottle, executor: executor)
            print("Steam launching — sign in through the Steam window.")
            print("(watching for exit; the bottle shuts down when Steam closes)")
            await monitor.value
        case "backend" where args.count >= 3:
            guard let backend = GraphicsBackend(rawValue: args[2]) else {
                fputs("unknown backend \(args[2]) — use dxmt or dxvk\n", stderr)
                exit(1)
            }
            let bottle = try Bottle.load(from: URL(filePath: args[1]))
            let executor = try await currentExecutor()
            try GraphicsBackendDeployer.apply(backend, runtime: executor.runtime, bottle: bottle)
            var updated = bottle
            updated.settings.graphicsBackend = backend
            try updated.saveSettings()
            print("Deployed \(backend.rawValue) into \(bottle.settings.name)")
        case "launcher" where args.count >= 3:
            let bottle = try Bottle.load(from: URL(filePath: args[1]))
            let games = try SteamStore().installedGames(in: bottle)
            guard let game = games.first(where: { $0.storeGameID == args[2] }) else {
                fputs("no installed game with appid \(args[2])\n", stderr)
                exit(1)
            }
            let appURL = try LauncherExporter.export(game: game, bottle: bottle)
            print(appURL.path(percentEncoded: false))
        case "games" where args.count >= 2:
            let bottle = try Bottle.load(from: URL(filePath: args[1]))
            for game in try SteamStore().installedGames(in: bottle) {
                print("\(game.storeGameID)\t\(game.name)")
            }
        default:
            print(usage)
        }
    }

    static func currentExecutor() async throws -> WineExecutor {
        guard let runtime = await RuntimeStore().current() else {
            throw RuntimeStoreError.notInstalled(version: "(none — run: runtime install)")
        }
        return WineExecutor(runtime: runtime)
    }

    static func installRuntime() async throws {
        let manifest = RuntimeManifest.stableDefault
        print("Installing runtime \(manifest.version) — \(manifest.notes ?? "")")
        let store = RuntimeStore()
        let runtime = try await store.install(manifest) { progress in
            switch progress {
            case .downloading(let done, let total):
                if let total {
                    let percent = Int(Double(done) / Double(total) * 100)
                    print("\rdownloading: \(percent)% (\(done / 1_048_576) MB)", terminator: "")
                } else {
                    print("\rdownloading: \(done / 1_048_576) MB", terminator: "")
                }
                fflush(stdout)
            case .verifying: print("\nverifying checksum…")
            case .extracting: print("extracting…")
            case .finishing: print("finishing…")
            }
        }
        let version = try await WineExecutor(runtime: runtime).wineVersion()
        print("Installed runtime \(runtime.version) (wine \(version)) at \(runtime.rootDirectory.path(percentEncoded: false))")
    }

    static func createBottle(named name: String) async throws {
        guard Rosetta2.isInstalled else {
            fputs("Rosetta 2 is required. Install with: softwareupdate --install-rosetta\n", stderr)
            exit(1)
        }
        let executor = try await currentExecutor()
        let bottle = try await BottleStore().create(name: name)
        print("Created \(bottle.url.path(percentEncoded: false)); initializing prefix…")
        try await executor.initializePrefix(for: bottle)
        try await executor.applyRegistrySettings(for: bottle)
        try GraphicsBackendDeployer.apply(
            bottle.settings.graphicsBackend, runtime: executor.runtime, bottle: bottle
        )
        print("Bottle \"\(name)\" ready (Windows \(bottle.settings.windowsVersion.rawValue), \(bottle.settings.graphicsBackend.rawValue)).")
    }
}
