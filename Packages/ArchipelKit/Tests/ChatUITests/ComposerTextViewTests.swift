import AppKit
@testable import ChatUI
import SwiftUI
import Testing

/// Hosts the composer's text view in an offscreen window, which is what gives it an undo manager.
@MainActor
@Suite struct ComposerTextViewTests {
    private func makeTextView() -> (NSWindow, ComposerNSTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let textView = ComposerNSTextView(frame: window.contentView?.bounds ?? .zero)
        textView.allowsUndo = true
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        return (window, textView)
    }

    private func type(_ text: String, into textView: NSTextView) {
        textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test func undoAfterTheDraftWasClearedDoesNotThrow() throws {
        let (window, textView) = makeTextView()
        type("hello world", into: textView)
        let undoManager = try #require(textView.undoManager)
        #expect(undoManager.canUndo)

        textView.replaceText(with: "")
        // An undo of the typing would ask for range {0, 11} of an empty string and raise.
        undoManager.undo()
        #expect(textView.string == "")
        _ = window
    }

    @Test func typingAfterAReplacementUndoesBackToTheReplacement() throws {
        let (window, textView) = makeTextView()
        type("/rev", into: textView)
        textView.replaceText(with: "/review ")
        #expect(textView.selectedRange() == NSRange(location: 8, length: 0))

        type("this", into: textView)
        #expect(textView.string == "/review this")
        let undoManager = try #require(textView.undoManager)
        undoManager.undo()
        #expect(textView.string == "/review ")
        undoManager.undo()
        #expect(textView.string == "/review ")
        _ = window
    }

    @Test func replacingAMentionLeavesTheCursorBehindItAndCanBeUndone() throws {
        let (window, textView) = makeTextView()
        // The typing and the choice are two events in the app. Without a run loop to tell them
        // apart, the test draws the line between their undo groups itself.
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        type("look at @Chat and more", into: textView)
        undoManager.endUndoGrouping()
        textView.setSelectedRange(NSRange(location: 13, length: 0))

        undoManager.beginUndoGrouping()
        #expect(textView.replaceAsTyped(NSRange(location: 8, length: 5), with: "ChatView.swift"))
        undoManager.endUndoGrouping()
        #expect(textView.string == "look at ChatView.swift and more")
        // Where the mention was, not at the end of the draft.
        #expect(textView.selectedRange() == NSRange(location: 22, length: 0))

        // Undo takes back the choice alone; what was typed around it is still there.
        undoManager.undo()
        #expect(textView.string == "look at @Chat and more")
        undoManager.undo()
        #expect(textView.string == "")
        _ = window
    }

    @Test func whatAReplacementDoesBesidesTheTextIsUndoneAndRedoneWithIt() throws {
        let (window, textView) = makeTextView()
        let undoManager = try #require(textView.undoManager)
        undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping()
        type("look at @Chat", into: textView)
        undoManager.endUndoGrouping()

        // The choice of a mention: the name into the text and the file into the attachments.
        var attachments = ["ChatView.swift"]
        undoManager.beginUndoGrouping()
        #expect(textView.replaceAsTyped(
            NSRange(location: 8, length: 5), with: "ChatView.swift ",
            alongside: .init(undo: { attachments.removeAll() }, redo: { attachments.append("ChatView.swift") })
        ))
        undoManager.endUndoGrouping()

        // One step back takes both, so no chip is left behind for a name that is gone.
        undoManager.undo()
        #expect(textView.string == "look at @Chat")
        #expect(attachments.isEmpty)
        undoManager.redo()
        #expect(textView.string == "look at ChatView.swift ")
        #expect(attachments == ["ChatView.swift"])
        undoManager.undo()
        #expect(textView.string == "look at @Chat")
        #expect(attachments.isEmpty)
        // The typing before it is a step of its own.
        undoManager.undo()
        #expect(textView.string == "")
        _ = window
    }

    @Test func aSentDraftTakesItsAttachmentUndoAlong() throws {
        let (window, textView) = makeTextView()
        let undoManager = try #require(textView.undoManager)
        var attachments = ["ChatView.swift"]
        type("@Chat", into: textView)
        #expect(textView.replaceAsTyped(
            NSRange(location: 0, length: 5), with: "ChatView.swift ",
            alongside: .init(undo: { attachments.removeAll() }, redo: {})
        ))
        // What a send does. Undo afterwards must not reach back into the prompt that went out.
        textView.replaceText(with: "")
        undoManager.undo()
        #expect(attachments == ["ChatView.swift"])
        #expect(textView.string == "")
        _ = window
    }

    @Test func aReplacementOutsideTheTextIsRefused() {
        let (window, textView) = makeTextView()
        type("@Chat", into: textView)
        #expect(!textView.replaceAsTyped(NSRange(location: 3, length: 9), with: "x"))
        #expect(!textView.replaceAsTyped(NSRange(location: NSNotFound, length: 0), with: "x"))
        #expect(textView.string == "@Chat")
        _ = window
    }

    @Test func aReplacementIsRefusedWhileAnInputMethodComposes() {
        let (window, textView) = makeTextView()
        type("@", into: textView)
        textView.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.hasMarkedText())
        #expect(!textView.replaceAsTyped(NSRange(location: 0, length: 3), with: "日本.txt "))
        #expect(textView.string == "@にほ")
        _ = window
    }

    @Test func theEditorReplacesThroughItsTextViewAndNotWithoutOne() {
        let editor = ComposerEditor()
        #expect(!editor.replace(NSRange(location: 0, length: 0), with: "x"))
    }

    /// What the composer keeps of its text view: the draft and where the cursor is in it.
    private final class Draft {
        var text: String
        var selections: [NSRange] = []

        init(_ text: String) {
            self.text = text
        }
    }

    /// The SwiftUI view around the text view, in an offscreen window, with the hold on it that
    /// the composer has.
    private func makeComposer(_ draft: Draft) throws -> (NSWindow, ComposerEditor, ComposerNSTextView) {
        let editor = ComposerEditor()
        let view = ComposerTextView(
            text: Binding(get: { draft.text }, set: { draft.text = $0 }),
            height: .constant(ComposerTextView.lineHeight),
            focusRequests: 0,
            accessibilityLabel: "Message",
            editor: editor,
            onSelectionChange: { draft.selections.append($0) },
            onCommand: { _, _ in .passThrough },
            onFiles: { _ in }
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, editor, try #require(editor.textView))
    }

    @Test func typingReportsTheTextAndTheCursorTogether() throws {
        let draft = Draft("")
        let (window, _, textView) = try makeComposer(draft)
        type("see @Cha", into: textView)
        #expect(draft.text == "see @Cha")
        #expect(draft.selections.last == NSRange(location: 8, length: 0))

        // Moving the cursor back into the mention changes no text and is reported all the same.
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(draft.text == "see @Cha")
        #expect(draft.selections.last == NSRange(location: 6, length: 0))
        // A cursor that did not move is not reported again.
        let count = draft.selections.count
        textView.setSelectedRange(NSRange(location: 6, length: 0))
        #expect(draft.selections.count == count)
        _ = window
    }

    @Test func anEditThroughTheEditorReachesTheDraftAndLeavesTheCursorBehindIt() throws {
        let draft = Draft("")
        let (window, editor, textView) = try makeComposer(draft)
        type("see @Cha now", into: textView)
        textView.setSelectedRange(NSRange(location: 8, length: 0))

        #expect(editor.replace(NSRange(location: 4, length: 4), with: "ChatView.swift"))
        #expect(draft.text == "see ChatView.swift now")
        #expect(draft.selections.last == NSRange(location: 18, length: 0))
        _ = window
    }

    @Test func aDraftThatWasThereBeforeTheViewReportsItsCursor() async throws {
        let draft = Draft("@read")
        let (window, _, textView) = try makeComposer(draft)
        #expect(textView.string == "@read")
        // Reported a turn of the run loop later, since the view is still being made.
        for _ in 0..<20 where draft.selections.isEmpty { await Task.yield() }
        #expect(draft.selections.last == textView.selectedRange())
        _ = window
    }
}
