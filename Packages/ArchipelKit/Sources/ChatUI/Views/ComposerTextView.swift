import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The composer's text: an AppKit text view, because the keys have to be exact. SwiftUI's
/// vertical `TextField` submits on Return but cannot tell Shift-Return apart, and it takes the
/// Return that commits an input method's composition. Here commands arrive through
/// `doCommandBy`, after the input method had its turn, and the view grows with its text up to
/// `maximumLines` and scrolls from there.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    /// The height the text wants, between one line and `maximumLines`.
    @Binding var height: CGFloat
    /// Takes the cursor whenever this changes, and when the view first appears.
    let focusRequests: Int
    var maximumLines = 8
    let accessibilityLabel: String
    /// Gets hold of the text view, for edits at the cursor.
    let editor: ComposerEditor
    /// The selection after every move of it, in UTF-16 units. A file mention is completed where
    /// the cursor is, which the text alone does not say.
    let onSelectionChange: @MainActor (NSRange) -> Void
    /// Decides what a key does and carries it out, except for the two things only the text view
    /// can do: `.insertNewline` and `.passThrough`.
    let onCommand: @MainActor (ComposerCommand, _ hasMarkedText: Bool) -> ComposerAction
    /// Files that were pasted or dropped.
    let onFiles: @MainActor ([URL]) -> Void

    static var font: NSFont { .preferredFont(forTextStyle: .body) }

    static var lineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(for: font).rounded(.up)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = ComposerNSTextView(usingTextLayoutManager: false)
        textView.delegate = context.coordinator
        textView.onFiles = { [coordinator = context.coordinator] urls in coordinator.parent.onFiles(urls) }
        textView.font = Self.font
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = false
        // Prompts are full of code, flags and quoted strings that must arrive as typed.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.string = text
        textView.setAccessibilityIdentifier("chat.composer")
        textView.setAccessibilityLabel(accessibilityLabel)
        // A wrapped line changes the height without the text changing, when the pane is resized.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.frameChanged(_:)),
            name: NSView.frameDidChangeNotification, object: textView
        )

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView
        context.coordinator.textView = textView
        editor.textView = textView
        // A draft that was there before the view puts the cursor at its end.
        context.coordinator.reportSelection(deferred: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.setAccessibilityLabel(accessibilityLabel)
        // Never while an input method composes: replacing the string would throw its marked text
        // away mid-word.
        if textView.string != text, !textView.hasMarkedText() {
            coordinator.isUpdatingView = true
            textView.replaceText(with: text)
            coordinator.isUpdatingView = false
            coordinator.updateHeight()
            coordinator.reportSelection(deferred: true)
        }
        if coordinator.lastFocusRequest != focusRequests {
            coordinator.lastFocusRequest = focusRequests
            textView.claimFocus()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        var lastFocusRequest: Int?
        /// Set while `updateNSView` replaces the text, when the selection moves inside a SwiftUI
        /// update and cannot be reported on the spot.
        var isUpdatingView = false
        /// What the composer was told last, so only a selection that moved is reported.
        private var reportedSelection: NSRange?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            reportSelection(deferred: isUpdatingView)
        }

        /// Typing reports at once, so the composer sees the new text and cursor in one update.
        /// `deferred` is for a move made inside a SwiftUI update, where state cannot change.
        func reportSelection(deferred: Bool) {
            guard !deferred else {
                Task { @MainActor [weak self] in self?.reportSelection(deferred: false) }
                return
            }
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection != reportedSelection else { return }
            reportedSelection = selection
            parent.onSelectionChange(selection)
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string { parent.text = textView.string }
            updateHeight()
        }

        @objc func frameChanged(_ notification: Notification) {
            updateHeight()
        }

        func updateHeight() {
            guard let textView, let container = textView.textContainer, let layoutManager = textView.layoutManager else { return }
            layoutManager.ensureLayout(for: container)
            let line = ComposerTextView.lineHeight
            let used = layoutManager.usedRect(for: container).height.rounded(.up)
            let height = min(max(used, line), line * CGFloat(parent.maximumLines))
            guard abs(parent.height - height) > 0.5 else { return }
            // This can run inside a SwiftUI update (`updateNSView`), where changing state is not
            // allowed; the next turn of the run loop is early enough for a height.
            Task { @MainActor [weak self] in
                guard let self, abs(self.parent.height - height) > 0.5 else { return }
                self.parent.height = height
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let command: ComposerCommand
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                // Shift-Return arrives as a plain insertNewline:, so the event has to say.
                let event = (textView as? ComposerNSTextView)?.keyEvent ?? NSApp.currentEvent
                let flags = event?.modifierFlags ?? []
                command = .newline(modified: !flags.isDisjoint(with: [.shift, .option]))
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
                command = .newline(modified: true)
            case #selector(NSResponder.insertTab(_:)): command = .tab
            case #selector(NSResponder.insertBacktab(_:)): command = .backtab
            case #selector(NSResponder.cancelOperation(_:)): command = .escape
            case #selector(NSResponder.moveUp(_:)): command = .up
            case #selector(NSResponder.moveDown(_:)): command = .down
            default: return false
            }
            switch parent.onCommand(command, textView.hasMarkedText()) {
            case .passThrough:
                return false
            case .insertNewline:
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            default:
                return true
            }
        }
    }
}

/// The composer's hold on its text view, for the one thing a binding to the text cannot do: an
/// edit at the cursor that leaves the cursor there. Setting the text through the binding puts the
/// cursor at the end and drops the undo history.
@MainActor
final class ComposerEditor {
    fileprivate(set) weak var textView: ComposerNSTextView?

    /// See `ComposerNSTextView.replaceAsTyped`. False as well before the text view exists.
    @discardableResult
    func replace(_ range: NSRange, with text: String, alongside: ComposerNSTextView.SideEffect? = nil) -> Bool {
        textView?.replaceAsTyped(range, with: text, alongside: alongside) ?? false
    }
}

final class ComposerNSTextView: NSTextView {
    var onFiles: (([URL]) -> Void)?
    private var wantsFocus = false
    /// The key press being handled, for the delegate to read the modifiers from. More exact than
    /// the application's current event, which is whatever was dequeued last.
    private(set) var keyEvent: NSEvent?

    override func keyDown(with event: NSEvent) {
        keyEvent = event
        defer { keyEvent = nil }
        super.keyDown(with: event)
    }

    /// Takes the cursor now, or as soon as the view is in a window: the first request usually
    /// comes while the chat is still being put on screen.
    func claimFocus() {
        guard let window else {
            wantsFocus = true
            return
        }
        wantsFocus = false
        // Deferred, so it also wins against whatever the tab switch that showed the chat made
        // first responder in the same event.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if wantsFocus, window != nil { claimFocus() }
    }

    /// Puts in text the app chose, such as the empty draft after a send or a slash command, with
    /// the cursor at its end.
    ///
    /// The typing the undo stack remembers refers to ranges of the old text, and undoing it over
    /// the new one raises an out-of-range exception, so that history is dropped. Typing registers
    /// its undo with the text storage; the view is included for the operations it registers
    /// itself. Only actions with these targets go: the undo manager is the window's, shared with
    /// every other view in it. The replacement itself is not undoable on purpose: after a send,
    /// Undo bringing the sent prompt back into the field would read as if it had not been sent.
    func replaceText(with text: String) {
        breakUndoCoalescing()
        string = text
        if let undoManager {
            undoManager.removeAllActions(withTarget: self)
            if let textStorage { undoManager.removeAllActions(withTarget: textStorage) }
        }
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    /// Replaces `range` the way typing would: the rest of the text and its undo history stay, the
    /// change can be undone, and the cursor ends up behind the new text. For an edit in the middle
    /// of a draft, where `replaceText(with:)` would throw away what was typed around it.
    ///
    /// `alongside` is what else the edit does outside the text, such as attaching the file a
    /// mention names. It joins the edit's undo step. The caller does it the first time.
    ///
    /// False, changing nothing, when the range is not in the text or an input method is
    /// composing: its marked text is not the app's to replace.
    @discardableResult
    func replaceAsTyped(_ range: NSRange, with text: String, alongside: SideEffect? = nil) -> Bool {
        guard !hasMarkedText(), range.location != NSNotFound, NSMaxRange(range) <= (string as NSString).length else { return false }
        // A step of its own for Undo, apart from the typing before and after it.
        breakUndoCoalescing()
        insertText(text, replacementRange: range)
        // Same event as the text's own undo, so the two form one group. The text view is the
        // target, so `replaceText(with:)` drops it along with the typing.
        if let alongside { registerUndo(alongside.undo, redo: alongside.redo) }
        breakUndoCoalescing()
        return true
    }

    /// Something an edit did besides changing the text, and how to take it back and do it again.
    struct SideEffect {
        var undo: @MainActor () -> Void
        var redo: @MainActor () -> Void
    }

    private func registerUndo(_ undo: @escaping @MainActor () -> Void, redo: @escaping @MainActor () -> Void) {
        undoManager?.registerUndo(withTarget: self) { view in
            MainActor.assumeIsolated {
                undo()
                // Registered while undoing, this is what Redo runs, and the other way around.
                view.registerUndo(redo, redo: undo)
            }
        }
    }

    // MARK: Files

    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Adds files and images, so Paste is enabled for a copied screenshot although this is a
    /// plain text view.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL] + Self.imageTypes
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(on: pasteboard) {
            onFiles?(urls)
        } else if pasteboard.availableType(from: [.string]) == nil, let url = Self.saveImage(from: pasteboard) {
            onFiles?([url])
        } else {
            pasteAsPlainText(sender)
        }
    }

    /// Only files are accepted as drops. Left to itself the text view would take a dropped file
    /// and insert its path as text.
    override func updateDragTypeRegistration() {
        unregisterDraggedTypes()
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        Self.fileURLs(on: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = Self.fileURLs(on: sender.draggingPasteboard) else { return false }
        onFiles?(urls)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {}

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return urls?.isEmpty == false ? urls : nil
    }

    /// A pasted image has no file, and an attachment is a file URL, so it is written out as a
    /// PNG. The system clears the temporary directory in its own time.
    private static func saveImage(from pasteboard: NSPasteboard) -> URL? {
        guard let type = pasteboard.availableType(from: imageTypes), let data = pasteboard.data(forType: type) else { return nil }
        let png: Data? = type == .png ? data : NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:])
        guard let png else { return nil }
        let folder = FileManager.default.temporaryDirectory.appending(path: "ChatAttachments", directoryHint: .isDirectory)
        let url = folder.appending(path: "Pasted Image \(UUID().uuidString.prefix(8)).png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
