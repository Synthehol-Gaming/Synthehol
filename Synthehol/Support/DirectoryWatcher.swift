import Foundation

/// Watches a directory for content changes (kqueue via DispatchSource) with
/// debouncing. Used on `steamapps/` so freshly installed games appear in the
/// library without a manual refresh.
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject
    private var debounce: DispatchWorkItem?

    init?(url: URL, debounceSeconds: Double = 2.0, onChange: @escaping @MainActor () -> Void) {
        let fd = open(url.path(percentEncoded: false), O_EVTONLY)
        guard fd >= 0 else { return nil }
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: .main
        )
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            self?.debounce?.cancel()
            let work = DispatchWorkItem {
                Task { @MainActor in onChange() }
            }
            self?.debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
        }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}
