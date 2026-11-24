import AppKit
@testable import ChatUI
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
}
