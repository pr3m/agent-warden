import Foundation

/// Watches a directory for writes and calls back on the main queue, coalescing bursts.
///
/// A hook can drop several files in a few milliseconds; without debouncing the app would rebuild
/// its UI once per file. The periodic sweep is the safety net if the watcher ever misses an event
/// (for example the directory being replaced wholesale).
final class DirectoryWatcher {
    private let url: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?

    init(url: URL, debounce: TimeInterval = 0.12, onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stop()
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in self?.schedule() }
        source.setCancelHandler { [descriptor] in
            if descriptor >= 0 { close(descriptor) }
        }
        self.source = source
        source.resume()
    }

    private func schedule() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.onChange() }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + self.debounce, execute: work)
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    deinit { stop() }
}
