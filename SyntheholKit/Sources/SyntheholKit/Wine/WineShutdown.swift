import Foundation

/// Last-resort bottle shutdown for app termination paths, where there is no
/// time for actors or async: reads the bottle registry directly and fires
/// `wineserver -k` per bottle. The wineserver processes finish independently
/// of the exiting app.
public enum WineShutdown {
    public static func killAllBottlesSync(
        registryURL: URL = SyntheholPaths.bottleRegistry,
        runtimesDirectory: URL = SyntheholPaths.runtimes
    ) {
        let wineserver = runtimesDirectory
            .appending(path: "current/Libraries/Wine/bin/wineserver")
        guard FileManager.default.isExecutableFile(
            atPath: wineserver.path(percentEncoded: false)
        ) else { return }

        guard let data = FileManager.default.contents(
            atPath: registryURL.path(percentEncoded: false)
        ),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let paths = (plist as? [String: Any])?["paths"] as? [String]
        else { return }

        for path in paths {
            let process = Process()
            process.executableURL = wineserver
            process.arguments = ["-k"]
            process.environment = ["WINEPREFIX": path]
            try? process.run()
        }
    }
}
