import AppKit
import Observation
import UniformTypeIdentifiers

/// Owns the open text buffers so unsaved edits survive tab switches (the hosting SwiftUI view is
/// destroyed whenever its tab is not selected) and the same file shown in two panes shares one buffer.
///
/// Buffers are keyed by the file a path leads to, with symlinks resolved. Opened once through a
/// link and once directly, a file would otherwise get two buffers, and whichever saved last would
/// silently undo the other's edits.
@MainActor @Observable
public final class FileDocumentStore {
    /// The files with unsaved changes, each under the path it was first opened by. That is the
    /// path the user saw, and for a file inside a worktree it stays inside that worktree, which
    /// the resolved one need not.
    public private(set) var dirtyURLs: Set<URL> = []
    @ObservationIgnored private var buffers: [URL: TextBuffer] = [:]
    /// Every path a buffer was asked for, mapped to the buffer's key. Remembered rather than
    /// resolved again on each lookup: the answer changes when the file is deleted or a link is
    /// repointed, and a buffer that can no longer be found can be neither saved nor closed.
    @ObservationIgnored private var keys: [URL: URL] = [:]

    public init() {}

    public func isDirty(_ url: URL) -> Bool {
        // Read before anything else so an observer is registered even while nothing is dirty.
        let dirty = dirtyURLs
        guard !dirty.isEmpty, let buffer = buffers[key(for: url)] else { return false }
        return dirty.contains(buffer.url)
    }

    /// Does nothing when the file is not open or has no unsaved changes. Throws without writing when
    /// the file changed on disk underneath the edits and the user has not chosen to overwrite it.
    public func save(_ url: URL) throws {
        try buffers[key(for: url)]?.save()
    }

    /// Saves every dirty buffer it can, then reports the first failure.
    public func saveAll() throws {
        var firstError: Error?
        let dirty = buffers.values.filter { dirtyURLs.contains($0.url) }
        for buffer in dirty.sorted(by: { $0.url.path < $1.url.path }) {
            do {
                try buffer.save()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Reverts the buffer to what is on disk.
    public func discardChanges(_ url: URL) {
        buffers[key(for: url)]?.discardChanges()
    }

    /// The app calls this when the last tab showing `url` closes. The buffer goes with the last
    /// path it was opened by: tabs that reached the same file another way are still using it.
    public func close(_ url: URL) {
        let key = keys.removeValue(forKey: url.standardizedFileURL) ?? key(for: url)
        guard !keys.values.contains(key), let buffer = buffers.removeValue(forKey: key) else { return }
        buffer.close()
        dirtyURLs.remove(buffer.url)
    }

    /// For a file that is gone for good, such as one in a worktree that was just deleted. Unlike
    /// `close` this takes the buffer whatever other paths still lead to it: left behind, its edits
    /// could never be saved, and would fail every Save All and be asked about at every quit.
    public func forget(_ url: URL) {
        let key = key(for: url)
        keys = keys.filter { $0.value != key }
        guard let buffer = buffers.removeValue(forKey: key) else { return }
        buffer.close()
        dirtyURLs.remove(buffer.url)
    }

    /// Whether both paths lead to the same buffer, which two different paths do when one of them
    /// goes through a symlink.
    public func sharesBuffer(_ first: URL, _ second: URL) -> Bool {
        key(for: first) == key(for: second)
    }

    func buffer(for url: URL) -> TextBuffer {
        let opened = url.standardizedFileURL
        let key = key(for: opened)
        keys[opened] = key
        if let buffer = buffers[key] { return buffer }
        let buffer = TextBuffer(url: opened, fileURL: key) { [weak self] isDirty in
            guard let self else { return }
            if isDirty { dirtyURLs.insert(opened) } else { dirtyURLs.remove(opened) }
        }
        buffers[key] = buffer
        return buffer
    }

    private func key(for url: URL) -> URL {
        let standardized = url.standardizedFileURL
        return keys[standardized] ?? standardized.resolvingSymlinksInPath()
    }
}

/// One open file: its text, undo history, on-disk format and the bookkeeping that tells an
/// external change apart from our own save.
@MainActor @Observable
final class TextBuffer: NSObject, NSTextStorageDelegate {
    enum State: Equatable {
        case loading
        case text
        case preview
        case missing
        case unreadable(String)
        case tooLarge(Int64)
        case binary
    }

    enum Conflict: Equatable {
        case changed, deleted
    }

    nonisolated static let maximumTextSize: Int64 = 5_000_000

    /// The path the file was first opened by, for showing and for `FileDocumentStore.dirtyURLs`.
    let url: URL
    /// The file itself, with the symlinks of `url` resolved when it was opened. Everything that
    /// touches the disk goes here. Going through `url` would follow a link as it is now: once that
    /// link is deleted or repointed, a save from a tab showing the real file would report the file
    /// as deleted, or write to wherever the link leads today.
    let fileURL: URL
    let grammar: String?
    private(set) var state = State.loading
    private(set) var isDirty = false
    /// Set when the file changed on disk while the buffer had unsaved edits.
    private(set) var conflict: Conflict?
    var saveError: String?
    /// Bumped on every change on disk, for views that reload themselves (Quick Look).
    private(set) var revision = 0

    @ObservationIgnored let textStorage = NSTextStorage()
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored private(set) var format = TextFileFormat()
    @ObservationIgnored private(set) var indentation = IndentationStyle.tab
    /// Where views left off, so switching tabs away and back lands in the same place.
    @ObservationIgnored var savedScrollOrigin: NSPoint?
    @ObservationIgnored var savedSelection: [NSValue]?

    @ObservationIgnored private var savedText = ""
    @ObservationIgnored private var fingerprint: FileFingerprint?
    @ObservationIgnored private var pendingDiskText: (text: String, format: TextFileFormat)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var watchCount = 0
    @ObservationIgnored private let onDirtyChange: (Bool) -> Void
#if DEBUG
    /// Preview samples have no file behind them, so a reload would only turn them into "missing".
    @ObservationIgnored fileprivate var isPreviewSample = false
#endif

    init(url: URL, fileURL: URL? = nil, onDirtyChange: @escaping (Bool) -> Void) {
        self.url = url
        self.fileURL = fileURL ?? url
        self.onDirtyChange = onDirtyChange
        grammar = SourceLanguage.grammar(forFileName: url.lastPathComponent)
        super.init()
        textStorage.delegate = self
    }

    var name: String { url.lastPathComponent }
    var text: String { textStorage.string }

    // MARK: Watching

    /// Views call this while they are visible; the buffer watches the file as long as one does.
    func beginWatching() {
        watchCount += 1
        guard watcher == nil else { return }
        let watcher = FileWatcher(url: fileURL) { [weak self] in
            Task { await self?.reload() }
        }
        watcher.rearm()
        self.watcher = watcher
    }

    func endWatching() {
        watchCount = max(0, watchCount - 1)
        guard watchCount == 0 else { return }
        watcher?.stop()
        watcher = nil
    }

    fileprivate func close() {
        watcher?.stop()
        watcher = nil
    }

    // MARK: Loading

    /// Reads the file if it changed since the last look. A clean buffer takes the new contents; a
    /// dirty one keeps the user's edits and raises a conflict instead.
    func reload() async {
#if DEBUG
        if isPreviewSample { return }
#endif
        generation += 1
        let current = generation
        watcher?.rearm()
        let result = await Self.load(fileURL, unlessMatching: state == .loading ? nil : fingerprint)
        guard current == generation, let result else { return }
        fingerprint = result.fingerprint
        revision += 1

        switch result.content {
        case .text(let text, let format):
            if state == .text {
                if text == savedText {
                    conflict = nil
                    pendingDiskText = nil
                    return
                }
                if isDirty {
                    pendingDiskText = (text, format)
                    conflict = .changed
                    return
                }
            }
            replaceFromDisk(text, format: format)
            state = .text
        case .other(let newState):
            if state == .text, isDirty {
                if newState == .missing { conflict = .deleted }
                return
            }
            if state != newState { state = newState }
        }
    }

    /// Takes the disk version, throwing away unsaved edits.
    func discardChanges() {
        if let pending = pendingDiskText {
            replaceFromDisk(pending.text, format: pending.format)
        } else if conflict == .deleted {
            replaceFromDisk("", format: format)
            state = .missing
        } else {
            if conflict == .changed {
                // The disk version could not be read as text (too large, binary), so there is nothing
                // to show yet. Forgetting the fingerprint makes the reload below look at the file
                // again instead of trusting that the buffer already matches it.
                fingerprint = nil
            }
            replaceFromDisk(savedText, format: format)
        }
        Task { await reload() }
    }

    /// Dismisses a conflict; the next save overwrites the version on disk that raised it. A later
    /// change on disk no longer matches `fingerprint` and raises a new conflict.
    func keepChanges() {
        conflict = nil
        pendingDiskText = nil
    }

    private func replaceFromDisk(_ text: String, format: TextFileFormat) {
        pendingDiskText = nil
        conflict = nil
        self.format = format
        savedText = text
        indentation = IndentationStyle.detect(in: text)
        if textStorage.string != text {
            // Only the changed middle is replaced, so views keep their scroll position.
            let (range, replacement) = CodeScrollView.changedRange(from: textStorage.string, to: text)
            textStorage.beginEditing()
            textStorage.replaceCharacters(in: range, with: NSAttributedString(string: replacement, attributes: EditorTheme.textAttributes))
            textStorage.endEditing()
        }
        // Undo steps recorded against the old text would corrupt the new one.
        undoManager.removeAllActions()
        updateDirty()
    }

    // MARK: Saving

    func save() throws {
        guard state == .text, isDirty || conflict != nil else { return }
        try checkForExternalChange()
        do {
            let text = textStorage.string
            let data = try format.encode(text)
            // Write through a symlink to its target rather than replacing the link with a file. The
            // file can have become a link since it was opened.
            let target = fileURL.resolvingSymlinksInPath()
            let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            try data.write(to: target, options: .atomic)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            savedText = text
            // Recording what we just wrote is what keeps our own watcher from calling it a conflict.
            fingerprint = FileFingerprint(fileURL)
            // A reload that read the file before this write would put the old text back.
            generation += 1
            conflict = nil
            pendingDiskText = nil
            saveError = nil
            updateDirty()
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }

    /// The watcher only runs while a view shows the file, so a save from a hidden tab, Save All or
    /// quitting may be the first to notice an external change. Writing then would silently destroy
    /// it, so the save is refused until the user has answered the conflict bar.
    ///
    /// A pending conflict blocks the save as well. "Keep My Changes" clears it, and since
    /// `fingerprint` then already describes the version on disk the user agreed to overwrite, the
    /// next save goes through unless the file changed once more.
    private func checkForExternalChange() throws {
        let current = FileFingerprint(fileURL) ?? .missing
        // Preview samples have no fingerprint and nothing on disk to protect.
        if let fingerprint, current != fingerprint {
            self.fingerprint = current
            let disk = current.exists ? Self.readText(fileURL, fingerprint: current) : nil
            if !current.exists {
                pendingDiskText = nil
                conflict = .deleted
            } else if disk?.text == savedText {
                // Touched or rewritten with the same contents: nothing would be lost.
                pendingDiskText = nil
                conflict = nil
            } else {
                pendingDiskText = disk
                conflict = .changed
            }
        }
        if let conflict { throw SaveConflictError(fileName: name, conflict: conflict) }
    }

    private nonisolated static func readText(_ url: URL, fingerprint: FileFingerprint) -> (text: String, format: TextFileFormat)? {
        guard !fingerprint.isDirectory, fingerprint.size <= maximumTextSize, let data = try? Data(contentsOf: url) else { return nil }
        return TextSniffer.decodeWithFormat(data)
    }

    // MARK: Editing

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { updateDirty() }
    }

    private func updateDirty() {
        // Runs on every keystroke. Most edits change the length, which settles it without comparing
        // the whole bridged string; utf16.count of the native saved text is cached after the first call.
        let dirty = state == .text || state == .loading
            ? textStorage.length != savedText.utf16.count || textStorage.string != savedText
            : false
        guard dirty != isDirty else { return }
        isDirty = dirty
        onDirtyChange(dirty)
    }

    // MARK: Disk

    private enum Content {
        case text(String, TextFileFormat)
        case other(State)
    }

    @concurrent
    private nonisolated static func load(_ url: URL, unlessMatching previous: FileFingerprint?) async -> (content: Content, fingerprint: FileFingerprint)? {
        guard let fingerprint = FileFingerprint(url) else {
            return previous == nil || previous?.exists == true ? (.other(.missing), .missing) : nil
        }
        if fingerprint == previous { return nil }
        if fingerprint.isDirectory { return (.other(.unreadable(String(localized: "This is a folder."))), fingerprint) }
        if isPreviewable(url), !isTextInMediaClothing(url) { return (.other(.preview), fingerprint) }
        if fingerprint.size > maximumTextSize { return (.other(.tooLarge(fingerprint.size)), fingerprint) }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return (.other(.unreadable(error.localizedDescription)), fingerprint)
        }
        guard let decoded = TextSniffer.decodeWithFormat(data) else { return (.other(.binary), fingerprint) }
        return (.text(decoded.text, decoded.format), fingerprint)
    }

    /// Types Quick Look renders better than a text view. SVG and XBM are images to UTType but their
    /// source is what gets edited (an XBM is a C header), so they stay text.
    nonisolated static func isPreviewable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), !sourceImageTypes.contains(type.identifier) else { return false }
        let previewable: [UTType] = [.image, .pdf, .audiovisualContent, .font, .threeDContent, .presentation, .spreadsheet, .rtf, .rtfd]
        let documents = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"]
        return previewable.contains { type.conforms(to: $0) } || documents.contains(type.identifier)
    }

    private nonisolated static let sourceImageTypes: Set<String> = [UTType.svg.identifier, "public.xbitmap-image"]

    /// The extension often promises more than the file holds. `.ts` and `.mts` are MPEG transport
    /// streams to UTType but in a repo they are almost always TypeScript, a PEM `server.key` counts
    /// as a Keynote presentation, and `.obj`, `.ply`, `.stl`, `.dae` and `.usda` models are plain
    /// text more often than not. So look at the bytes: the real binary formats are full of NULs.
    ///
    /// Not for images, PDFs, fonts and RTF. Those can pass for text in their first few kilobytes
    /// (a PDF or RTF header, an ASCII PPM) and are still better off in Quick Look.
    nonisolated static func isTextInMediaClothing(_ url: URL) -> Bool {
        let renderedEvenAsText: [UTType] = [.image, .pdf, .font, .rtf]
        guard let type = UTType(filenameExtension: url.pathExtension),
              !renderedEvenAsText.contains(where: { type.conforms(to: $0) }),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: TextSniffer.sniffLength) else { return false }
        return !TextSniffer.isBinary(head)
    }
}

struct SaveConflictError: LocalizedError, Equatable {
    var fileName: String
    var conflict: TextBuffer.Conflict

    var errorDescription: String? {
        switch conflict {
        case .changed:
            String(localized: "\(fileName) changed on disk. Open it and choose Reload or Keep My Changes, then save again.")
        case .deleted:
            String(localized: "\(fileName) was deleted on disk. Open it and choose Keep My Changes to save it anyway.")
        }
    }
}

#if DEBUG
extension TextBuffer {
    /// A buffer in the given state without touching the disk. `edit` is appended after loading, so
    /// the buffer is dirty, which is what the conflict bar needs to show.
    static func previewSample(
        url: URL,
        text: String = "",
        state: State = .text,
        edit: String? = nil,
        conflict: Conflict? = nil,
        saveError: String? = nil
    ) -> TextBuffer {
        let buffer = TextBuffer(url: url) { _ in }
        buffer.isPreviewSample = true
        buffer.replaceFromDisk(text, format: TextFileFormat())
        buffer.state = state
        if let edit {
            buffer.textStorage.append(NSAttributedString(string: edit, attributes: EditorTheme.textAttributes))
        }
        buffer.conflict = conflict
        buffer.saveError = saveError
        return buffer
    }
}
#endif

/// Enough of `stat` to tell whether a file changed, including being replaced by a rename.
struct FileFingerprint: Equatable, Sendable {
    var exists = true
    var isDirectory = false
    var size: Int64 = 0
    var inode: UInt64 = 0
    var modified = timespec()

    static let missing = FileFingerprint(exists: false)

    init(exists: Bool) {
        self.exists = exists
    }

    init?(_ url: URL) {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
        size = Int64(info.st_size)
        inode = UInt64(info.st_ino)
        modified = info.st_mtimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.exists == rhs.exists && lhs.isDirectory == rhs.isDirectory && lhs.size == rhs.size && lhs.inode == rhs.inode
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }
}
