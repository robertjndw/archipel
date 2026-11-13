import Foundation

/// Calls back when a file changes on disk.
///
/// Editors and agents usually save by writing a temporary file and renaming it over the original,
/// which leaves a vnode watch pointing at the old, unlinked file. So after a delete or rename the
/// watch is dropped and re-armed on the path, and `rearm()` lets a periodic check pick the file up
/// again once it reappears.
@MainActor
final class FileWatcher {
    private let url: URL
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    var isArmed: Bool { source != nil }

    func rearm() {
        guard source == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handle() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func handle() {
        guard let source else { return }
        if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
            stop()
            rearm()
        }
        onChange()
    }
}
