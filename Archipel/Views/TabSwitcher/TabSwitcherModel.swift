import AppKit
import ArchipelCore
import GitKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What a card shows of its tab.
enum TabPreview: Equatable {
    /// The last lines of a terminal, read bottom up like the terminal itself.
    case terminal([String])
    /// The top of a text file, where the editor opens it.
    case text([String])
    case image(NSImage)
    /// The first changed lines with a little context.
    case diff([DiffPreviewLine])
}

struct DiffPreviewLine: Equatable {
    var kind: GitDiffLine.Kind
    var text: String
}

/// Ctrl-Tab between recently used tabs (sessions, files and diffs alike), the way Cmd-Tab moves
/// between apps.
///
/// Nothing switches until Control is let go, so a single tap flips between the last two tabs and a
/// held Control lets Tab walk further back. The panel only appears once Control has been held for
/// `panelDelay`, so a quick flip never flashes anything.
///
/// The panel opens with its previews in place. Files and diffs start loading on the first press, in
/// the background, and are usually back before the panel shows; terminals are read just before it
/// shows. Previews are also kept after the panel closes, so opening it again never waits on them.
@Observable
final class TabSwitcherModel {
    private(set) var gesture: TabSwitch?
    /// The tab in front when the gesture began.
    private(set) var startedFrom: ArchipelCore.Tab.ID?
    private(set) var showsPanel = false
    /// Survives the panel closing, so a reopened panel shows what it showed last time at once and
    /// only swaps in fresher content as it arrives. Pruned to the current candidates on each press.
    private(set) var previews: [ArchipelCore.Tab.ID: TabPreview] = [:]

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    static let panelDelay = Duration.milliseconds(180)
    /// Same as Arc. Older tabs are a ⌘K away, and a longer row outgrows the window.
    static let limit = 5
    nonisolated static let previewLines = 18
    /// Plenty for the lines a card shows, and keeps a minified file from being read whole.
    nonisolated private static let fileReadLimit = 16_384

    var isActive: Bool { gesture != nil }

    /// Ctrl-Tab (`offset` 1) or Ctrl-Shift-Tab (-1). Starts the gesture on the first press.
    func press(offset: Int, app: AppModel) {
        if gesture != nil {
            gesture?.advance(by: offset)
            return
        }
        // Of the tabs never visited, only running sessions are listed. Old file and diff tabs
        // would just be clutter.
        let candidates = app.recentTabs.candidates(in: app.workspace, includesUnvisited: { (tab: ArchipelCore.Tab) in
            if case .session(let id) = tab.content { return app.terminals[id] != nil }
            return false
        }, limit: Self.limit)
        guard var gesture = TabSwitch(candidates: candidates, current: app.focusedTab?.id) else {
            NSSound.beep()
            return
        }
        // Shift on the first press walks from the other end, as Cmd-Shift-Tab does.
        if offset < 0 { gesture.advance(by: -1 - gesture.selection) }
        self.app = app
        self.gesture = gesture
        startedFrom = app.focusedTab?.id
        let listed = Set(gesture.candidates)
        previews = previews.filter { listed.contains($0.key) }
        loadTask = Task { @MainActor [weak self] in
            await self?.loadStaticPreviews(for: gesture.candidates, app: app)
        }
        revealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.panelDelay)
            guard let self, !Task.isCancelled else { return }
            refreshTerminals()
            showsPanel = true
            while !Task.isCancelled {
                // Ghostty has no change notification, so this polls like the sidebar peek does.
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                refreshTerminals()
            }
        }
    }

    func step(by offset: Int) {
        gesture?.advance(by: offset)
    }

    func hover(_ id: ArchipelCore.Tab.ID) {
        gesture?.select(id)
    }

    /// Control let go, Return, or a click on a card.
    func commit() {
        guard let id = gesture?.selectedID, let app else { return reset() }
        reset()
        guard id != app.focusedTab?.id else { return }
        app.select(tab: id)
        app.focusFocusedTabSoon()
    }

    func cancel() {
        reset()
    }

    private func reset() {
        revealTask?.cancel()
        revealTask = nil
        loadTask?.cancel()
        loadTask = nil
        // The panel has to vanish at once: the chosen tab is already behind it. Without this the
        // cards' own animations and the glass play the reset back as a fade on the way out.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            gesture = nil
            startedFrom = nil
            showsPanel = false
        }
    }

    // MARK: Previews

    private func refreshTerminals() {
        guard let gesture, let app else { return }
        for id in gesture.candidates {
            guard case .session(let sessionID)? = app.workspace.tab(id: id)?.content,
                  let terminal = app.terminals[sessionID]
            else { continue }
            let preview = TabPreview.terminal(SessionPeek.tail(of: terminal.readVisibleText(), lines: Self.previewLines))
            if previews[id] != preview { previews[id] = preview }
        }
    }

    /// Files and diffs do not change while the panel is up, so they are read once per gesture and
    /// merged in one go rather than popping in one by one.
    private func loadStaticPreviews(for candidates: [ArchipelCore.Tab.ID], app: AppModel) async {
        var loaded: [ArchipelCore.Tab.ID: TabPreview] = [:]
        await withTaskGroup(of: (ArchipelCore.Tab.ID, TabPreview?).self) { group in
            for id in candidates {
                guard let tab = app.workspace.tab(id: id) else { continue }
                switch tab.content {
                case .session, .web:
                    continue
                case .file(let url):
                    group.addTask { (id, await Self.filePreview(url)) }
                case .diff(let path, let staged):
                    guard let root = app.workspace.worktree(containingTab: id)?.path else { continue }
                    let git = app.git
                    group.addTask { (id, await Self.diffPreview(path: path, staged: staged, root: root, git: git)) }
                }
            }
            for await (id, preview) in group {
                if let preview { loaded[id] = preview }
            }
        }
        // A gesture that ended while reading must not overwrite what the next one loads.
        guard !Task.isCancelled else { return }
        // Shown as saved on disk: unsaved edits live in the editor's buffer, which is not exposed.
        previews.merge(loaded) { _, new in new }
    }

    nonisolated private static func filePreview(_ url: URL) async -> TabPreview? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true {
            return NSImage(contentsOf: url).map(TabPreview.image)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: fileReadLimit), !data.contains(0) else { return nil }
        // A read cut off inside a multi-byte character would fail strict decoding.
        let text = String(decoding: data, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(previewLines + 4)
        return .text(lines.map { String($0).replacingOccurrences(of: "\t", with: "    ") })
    }

    nonisolated private static func diffPreview(path: String, staged: Bool, root: URL, git: GitClient) async -> TabPreview? {
        // Every line the preview can show lies within previewLines of the first change, so that much
        // context keeps them all in the first hunk without git emitting and us parsing the whole file.
        guard let diff = try? await git.fileDiff(path: path, staged: staged, contextLines: previewLines, in: root),
              !diff.isBinary
        else { return nil }
        // Start just above the first change.
        let lines = diff.hunks.flatMap(\.lines)
        let firstChange = lines.firstIndex { $0.kind != .context } ?? 0
        return .diff(lines.dropFirst(max(firstChange - 2, 0)).prefix(previewLines).map {
            DiffPreviewLine(kind: $0.kind, text: $0.text.replacingOccurrences(of: "\t", with: "    "))
        })
    }
}

#if DEBUG
extension TabSwitcherModel {
    /// Puts the panel up without a key press or reading any tab.
    func showForPreview(_ gesture: TabSwitch, startedFrom: ArchipelCore.Tab.ID?, previews: [ArchipelCore.Tab.ID: TabPreview] = [:]) {
        self.gesture = gesture
        self.startedFrom = startedFrom
        self.previews = previews
        showsPanel = true
    }
}
#endif

/// Takes Ctrl-Tab before the terminal does and watches for Control being let go. Lives in the main
/// window's background so it only acts on that window's keys.
struct TabSwitcherKeyMonitor: NSViewRepresentable {
    let switcher: TabSwitcherModel
    let model: AppModel
    /// The palette owns the keyboard while it is open.
    let isBlocked: () -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.switcher = switcher
        view.model = model
        view.isBlocked = isBlocked
    }

    final class MonitorView: LocalKeyMonitorView {
        weak var switcher: TabSwitcherModel?
        weak var model: AppModel?
        var isBlocked: () -> Bool = { false }
        private var resignObserver: (any NSObjectProtocol)?

        isolated deinit {
            if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        }

        override var eventMask: NSEvent.EventTypeMask { [.keyDown, .flagsChanged] }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Cmd-Tab away with Control still down would otherwise leave the panel up with nothing
            // to tell us when Control is let go.
            if resignObserver == nil {
                resignObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.switcher?.cancel() }
                }
            }
        }

        private enum Key {
            static let tab: UInt16 = 48
            static let escape: UInt16 = 53
            static let returnKey: UInt16 = 36
            static let enter: UInt16 = 76
            static let left: UInt16 = 123
            static let right: UInt16 = 124
        }

        override func handle(_ event: NSEvent) -> Bool {
            guard let switcher, let model else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if event.type == .flagsChanged {
                if switcher.isActive, !modifiers.contains(.control) { switcher.commit() }
                return false
            }

            if switcher.isActive {
                switch event.keyCode {
                case Key.tab: switcher.step(by: modifiers.contains(.shift) ? -1 : 1)
                case Key.right: switcher.step(by: 1)
                case Key.left: switcher.step(by: -1)
                case Key.returnKey, Key.enter: switcher.commit()
                case Key.escape: switcher.cancel()
                default:
                    // Anything else means the user moved on; let the key do its job.
                    switcher.cancel()
                    return false
                }
                return true
            }

            guard event.keyCode == Key.tab, modifiers.subtracting(.shift) == .control,
                  let window, event.window === window, window.attachedSheet == nil, !isBlocked()
            else { return false }
            switcher.press(offset: modifiers.contains(.shift) ? -1 : 1, app: model)
            return true
        }
    }
}
