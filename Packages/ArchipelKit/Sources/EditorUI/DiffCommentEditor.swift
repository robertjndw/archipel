import AppKit
import SwiftUI

/// The popover for writing or editing the comment on one diff line. One session per popover, so a
/// popover that is still animating closed cannot report into the next one.
@MainActor
final class DiffCommentEditorSession: NSObject, NSPopoverDelegate {
    enum Outcome: Equatable {
        case save(String)
        case delete
    }

    private let popover = NSPopover()
    private let draft: ReviewCommentDraft
    private let original: String
    private var completion: ((Outcome) -> Void)?

    init(title: String, code: String, body: String?, completion: @escaping (Outcome) -> Void) {
        draft = ReviewCommentDraft(text: body ?? "")
        original = body ?? ""
        self.completion = completion
        super.init()
        let editor = ReviewCommentEditor(draft: draft, title: title, code: code, isEditing: body != nil) { [weak self] outcome in
            self?.finish(outcome)
        }
        let controller = NSHostingController(rootView: editor)
        controller.sizingOptions = .preferredContentSize
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(relativeTo rect: NSRect, of view: NSView) {
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    /// Closes the popover without an explicit answer, keeping whatever was typed.
    func dismiss() {
        keepDraft()
        popover.close()
    }

    /// Nil cancels.
    private func finish(_ outcome: Outcome?) {
        let completion = self.completion
        self.completion = nil
        popover.close()
        if let outcome { completion?(outcome) }
    }

    /// A click elsewhere in the window dismisses a transient popover; throwing away a half-written
    /// comment then would be the worse surprise, so it is saved. Escape and Cancel discard it.
    private func keepDraft() {
        guard let completion else { return }
        self.completion = nil
        let text = draft.trimmedText
        if !text.isEmpty, text != original.trimmingCharacters(in: .whitespacesAndNewlines) {
            completion(.save(text))
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // NSPopover closes itself on Escape when the text view does not take it; that is a cancel.
        if let event = NSApp.currentEvent, event.type == .keyDown, event.keyCode == 53 {
            completion = nil
        }
        keepDraft()
    }
}

@MainActor @Observable
final class ReviewCommentDraft {
    var text: String

    init(text: String) {
        self.text = text
    }

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ReviewCommentEditor: View {
    @Bindable var draft: ReviewCommentDraft
    let title: String
    let code: String
    let isEditing: Bool
    let finish: (DiffCommentEditorSession.Outcome?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.headline)
                let trimmedCode = code.trimmingCharacters(in: .whitespaces)
                Text(verbatim: trimmedCode.isEmpty ? String(localized: "Blank line") : trimmedCode)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            CommentTextEditor(text: $draft.text, onSubmit: submit, onCancel: { finish(nil) })
                .frame(height: 84)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                .accessibilityLabel("Comment")
            HStack(spacing: 8) {
                if isEditing {
                    Button("Delete", role: .destructive) { finish(.delete) }
                }
                Spacer(minLength: 0)
                Button("Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add Comment", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isEditing && draft.trimmedText.isEmpty)
                    .help("Command-Return")
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 340)
    }

    private func submit() {
        let text = draft.trimmedText
        if !text.isEmpty {
            finish(.save(text))
        } else {
            // Emptying an existing comment and saving it is how a keyboard user deletes it.
            finish(isEditing ? .delete : nil)
        }
    }
}

/// Multi-line plain text where Return starts a new line, Command-Return saves and Escape cancels.
/// A SwiftUI TextEditor cannot tell Escape apart from its own completion handling, hence AppKit.
private struct CommentTextEditor: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = CommentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        // Comments quote code; curly quotes and dash substitution would change what the agent reads.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(String(localized: "Comment"))

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        update(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? CommentTextView else { return }
        if textView.string != text { textView.string = text }
        update(textView)
    }

    private func update(_ textView: CommentTextView) {
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

private final class CommentTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var hasFocusedOnce = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasFocusedOnce else { return }
        hasFocusedOnce = true
        window.makeFirstResponder(self)
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // 36 is Return, 76 the keypad's Enter.
        if modifiers == .command, event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// NSTextView answers Escape with word completion; here it means cancel.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
