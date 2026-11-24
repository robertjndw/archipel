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
            textView.replaceText(with: text)
            coordinator.updateHeight()
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

        init(_ parent: ComposerTextView) {
            self.parent = parent
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
