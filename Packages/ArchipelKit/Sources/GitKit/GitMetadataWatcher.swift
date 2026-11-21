import CoreServices
import Foundation

/// Reports writes anywhere under a repository's git directory, as paths relative to it.
///
/// FSEvents rather than a vnode watch, because refs live in nested folders (`refs/heads/feature/x`,
/// `worktrees/<name>/HEAD`) and a vnode watch sees only the one file or folder it was opened on.
/// Events arrive in batches, `latency` apart at most, on the main queue.
@MainActor
public final class GitMetadataWatcher {
    public struct Batch: Sendable {
        public var paths: [String]
        /// FSEvents dropped events somewhere other than objects, logs and the like, or the folder
        /// itself was moved or deleted. Anything may have changed then.
        public var mayHaveMissedChanges: Bool
    }

    public let directory: URL
    private var stream: FSEventStreamRef?

    /// Owned by the stream, so a batch already queued on main when the watcher goes away finds a
    /// nil `watcher` instead of a freed object.
    private final class Relay {
        weak var watcher: GitMetadataWatcher?
        let onChange: @MainActor (Batch) -> Void
        let root: String

        init(root: String, onChange: @escaping @MainActor (Batch) -> Void) {
            self.root = root
            self.onChange = onChange
        }
    }

    /// `directory` should be the common git directory, so one stream covers the main checkout and
    /// every linked worktree. A folder that does not exist yet is fine: FSEvents just reports
    /// nothing until it does.
    public init(directory: URL, latency: TimeInterval = 0.4, onChange: @escaping @MainActor (Batch) -> Void) {
        // FSEvents reports real paths (`/private/var/...`). resolvingSymlinksInPath would strip
        // `/private` again, realpath does not.
        let path = directory.path(percentEncoded: false)
        let root = realpath(path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? path
        self.directory = URL(filePath: root, directoryHint: .isDirectory)
        let relay = Relay(root: root.hasSuffix("/") ? String(root.dropLast()) : root, onChange: onChange)
        relay.watcher = self

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(relay).toOpaque(),
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<Relay>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, eventFlags, _ in
            guard let info else { return }
            let relay = Unmanaged<Relay>.fromOpaque(info).takeUnretainedValue()
            let all = unsafeBitCast(paths, to: NSArray.self)
            var batch = Batch(paths: [], mayHaveMissedChanges: false)
            let dropped = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            )
            let rootChanged = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
            let prefix = relay.root + "/"
            for index in 0..<count {
                let path = all[index] as? String
                // A case-insensitive volume can hand back a different spelling of the same root.
                let relative = path.flatMap { path -> String? in
                    guard path.count > prefix.count,
                          path.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
                    else { return nil }
                    return String(path.dropFirst(prefix.count))
                }
                if eventFlags[index] & rootChanged != 0 {
                    batch.mayHaveMissedChanges = true
                } else if eventFlags[index] & dropped != 0, !GitMetadataChange.isChurn(relativePath: relative ?? "") {
                    // Without a path below the root, FSEvents gave up on the whole folder.
                    batch.mayHaveMissedChanges = true
                }
                if let relative { batch.paths.append(relative) }
            }
            guard !batch.paths.isEmpty || batch.mayHaveMissedChanges else { return }
            MainActor.assumeIsolated {
                guard relay.watcher != nil else { return }
                relay.onChange(batch)
            }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<Relay>.fromOpaque(context.info!).release()
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Whether FSEvents accepted the stream. A watcher that did not start just never reports.
    public var isRunning: Bool { stream != nil }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    isolated deinit {
        stop()
    }
}
