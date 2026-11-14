import AppKit
import Observation
import UniformTypeIdentifiers

/// Owns the open text buffers, keyed by standardized file URL, so unsaved edits survive tab switches
/// (the hosting SwiftUI view is destroyed whenever its tab is not selected) and the same file shown in
/// two panes shares one buffer.
@MainActor @Observable
public final class FileDocumentStore {
    public private(set) var dirtyURLs: Set<URL> = []
    @ObservationIgnored private var buffers: [URL: TextBuffer] = [:]

    public init() {}

    public func isDirty(_ url: URL) -> Bool {
        dirtyURLs.contains(Self.key(url))
    }

    /// Does nothing when the file is not open or has no unsaved changes.
    public func save(_ url: URL) throws {
        try buffers[Self.key(url)]?.save()
    }

    /// Saves every dirty buffer it can, then reports the first failure.
    public func saveAll() throws {
        var firstError: Error?
        for url in dirtyURLs.sorted(by: { $0.path < $1.path }) {
            do {
                try buffers[url]?.save()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    /// Reverts the buffer to what is on disk.
    public func discardChanges(_ url: URL) {
        buffers[Self.key(url)]?.discardChanges()
    }

    /// Drops the buffer; the app calls this when the last tab for the file closes.
    public func close(_ url: URL) {
        let key = Self.key(url)
        buffers.removeValue(forKey: key)?.close()
        dirtyURLs.remove(key)
    }

    func buffer(for url: URL) -> TextBuffer {
        let key = Self.key(url)
        if let buffer = buffers[key] { return buffer }
        let buffer = TextBuffer(url: key) { [weak self] isDirty in
            guard let self else { return }
            if isDirty { dirtyURLs.insert(key) } else { dirtyURLs.remove(key) }
        }
        buffers[key] = buffer
        return buffer
    }

    private static func key(_ url: URL) -> URL {
        url.standardizedFileURL
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

    let url: URL
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

    init(url: URL, onDirtyChange: @escaping (Bool) -> Void) {
        self.url = url
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
        let watcher = FileWatcher(url: url) { [weak self] in
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
        generation += 1
        let current = generation
        watcher?.rearm()
        let result = await Self.load(url, unlessMatching: state == .loading ? nil : fingerprint)
        guard current == generation, let result else { return }
        fingerprint = result.fingerprint
        revision += 1

        switch result.content {
        case .text(let text, let format):
            if state == .text {
                if text == savedText {
                    conflict = nil
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
            replaceFromDisk(savedText, format: format)
        }
        Task { await reload() }
    }

    /// Dismisses a conflict; the next save overwrites whatever is on disk.
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
        do {
            let text = textStorage.string
            let data = try format.encode(text)
            // Write through a symlink to its target rather than replacing the link with a file.
            let target = url.resolvingSymlinksInPath()
            let permissions = try? FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions]
            try data.write(to: target, options: .atomic)
            if let permissions {
                try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
            }
            savedText = text
            // Recording what we just wrote is what keeps our own watcher from calling it a conflict.
            fingerprint = FileFingerprint(url)
            conflict = nil
            pendingDiskText = nil
            saveError = nil
            updateDirty()
        } catch {
            saveError = error.localizedDescription
            throw error
        }
    }

    // MARK: Editing

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated { updateDirty() }
    }

    private func updateDirty() {
        let dirty = state == .text || state == .loading ? textStorage.string != savedText : false
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
        if isPreviewable(url) { return (.other(.preview), fingerprint) }
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

    /// Types Quick Look renders better than a text view. SVG is an image to UTType but agents edit its
    /// source, so it stays text.
    nonisolated static func isPreviewable(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension), type != .svg else { return false }
        let previewable: [UTType] = [.image, .pdf, .audiovisualContent, .font, .threeDContent, .presentation, .spreadsheet, .rtf, .rtfd]
        let documents = ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "com.apple.iwork.pages.sffpages"]
        return previewable.contains { type.conforms(to: $0) } || documents.contains(type.identifier)
    }
}

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
