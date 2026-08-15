import Foundation

/// Keeps Steam's Chromium UI on software rendering without changing the
/// graphics backend used by games. Steam repairs `steamwebhelper.exe` during
/// every startup, so deployment happens after that repair and the helper is
/// restarted once. Valve's current binary is retained beside the shim and is
/// restored before the next launch so client updates remain free to replace it.
struct SteamWebHelperShim: Sendable {
    static let shimFileName = "steamwebhelper-shim.exe"
    static let valveFileName = "steamwebhelper_real.exe"
    static let wrapperSizeCeiling: UInt64 = 500_000

    private let shimURL: URL?

    init(
        shimURL: URL? = Bundle.module.url(forResource: "steamwebhelper-shim", withExtension: "exe")
    ) {
        self.shimURL = shimURL
    }

    /// Restores Valve's helper before Steam starts. This is deliberately
    /// synchronous so the bootstrapper never sees a pinned/replaced binary.
    func prepareForLaunch(in bottle: Bottle) {
        for directory in cefDirectories(in: bottle) {
            let target = directory.appending(path: "steamwebhelper.exe")
            let valve = directory.appending(path: Self.valveFileName)
            guard isShim(target), isValveHelper(valve) else { continue }
            do {
                try replaceItem(at: target, with: valve)
            } catch {
                Log.steam.error("Could not restore Steam WebHelper before update: \(error, privacy: .public)")
            }
        }
    }

    /// Installs the shim after Steam's startup repair. Returns true only when
    /// at least one Valve helper was newly wrapped, signalling that WebHelper
    /// should be restarted.
    @discardableResult
    func deploy(in bottle: Bottle) -> Bool {
        guard let shimURL else {
            Log.steam.error("Bundled Steam WebHelper shim is missing")
            return false
        }
        var changed = false
        for directory in cefDirectories(in: bottle) {
            let target = directory.appending(path: "steamwebhelper.exe")
            let valve = directory.appending(path: Self.valveFileName)
            guard isValveHelper(target) else { continue }
            do {
                // Steam may have updated CEF since the previous launch. Always
                // preserve the current file before replacing it.
                try replaceItem(at: valve, with: target)
                try replaceItem(at: target, with: shimURL)
                changed = true
            } catch {
                Log.steam.error("Could not deploy Steam WebHelper shim: \(error, privacy: .public)")
            }
        }
        return changed
    }

    func isDeployed(in bottle: Bottle) -> Bool {
        cefDirectories(in: bottle).contains { directory in
            isShim(directory.appending(path: "steamwebhelper.exe"))
        }
    }

    private func cefDirectories(in bottle: Bottle) -> [URL] {
        let root = bottle.url.appending(path: "drive_c/Program Files (x86)/Steam/bin/cef")
        return (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.lastPathComponent.hasPrefix("cef.win") } ?? []
    }

    private func isShim(_ url: URL) -> Bool {
        guard let size = fileSize(url) else { return false }
        return size > 0 && size < Self.wrapperSizeCeiling
    }

    private func isValveHelper(_ url: URL) -> Bool {
        guard let size = fileSize(url) else { return false }
        return size >= Self.wrapperSizeCeiling
    }

    private func fileSize(_ url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }

    private func replaceItem(at destination: URL, with source: URL) throws {
        let data = try Data(contentsOf: source)
        try data.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path(percentEncoded: false)
        )
    }
}
