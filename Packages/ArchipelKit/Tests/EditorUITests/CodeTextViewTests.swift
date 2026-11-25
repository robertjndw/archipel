import AppKit
import Testing
@testable import EditorUI

@MainActor
struct CodeTextViewTests {
    private func buffer(_ text: String) -> TextBuffer {
        TextBuffer.previewSample(url: URL(filePath: "/tmp/sample.swift"), text: text)
    }

    /// Types the way a key press does: through the text view, which records its own undo step.
    private func type(_ text: String, in view: CodeScrollView) {
        view.textView.insertText(text, replacementRange: view.textView.selectedRange())
    }

    /// AppKit closes an undo group at the end of each event, which a test has none of.
    private func keyPress(_ buffer: TextBuffer, _ action: () -> Void) {
        buffer.undoManager.groupsByEvent = false
        buffer.undoManager.beginUndoGrouping()
        action()
        buffer.undoManager.endUndoGrouping()
    }

    @Test func undoSurvivesTheViewBeingReplaced() {
        let buffer = buffer("let a = 1\n")
        autoreleasepool {
            let first = CodeScrollView(buffer: buffer)
            first.textView.setSelectedRange(NSRange(location: 9, length: 0))
            type("2", in: first)
            // A tab switch or a Source/Preview toggle: SwiftUI drops the view and later makes a new one.
            first.detach()
        }
        #expect(buffer.text == "let a = 12\n")
        let second = CodeScrollView(buffer: buffer)
        #expect(buffer.undoManager.canUndo)
        buffer.undoManager.undo()
        #expect(buffer.text == "let a = 1\n")
        buffer.undoManager.redo()
        #expect(buffer.text == "let a = 12\n")

        // The new view records undo steps of its own that undo just as well.
        second.textView.setSelectedRange(NSRange(location: 0, length: 0))
        type("// ", in: second)
        buffer.undoManager.undo()
        #expect(buffer.text == "let a = 12\n")
        second.detach()
    }

    @Test func tabIndentsEverySelectedLineAsOneUndoStep() {
        let buffer = buffer("func a() {\n    one()\n\n    two()\n}\n")
        #expect(buffer.indentation == .spaces(4))
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        // From the start of "one()" to the end of "two()", plus its newline.
        view.textView.setSelectedRange(NSRange(location: 11, length: 21))
        keyPress(buffer) { view.textView.insertTab(nil) }
        // The blank line between them gets no trailing whitespace.
        #expect(buffer.text == "func a() {\n        one()\n\n        two()\n}\n")
        #expect(view.textView.selectedRange() == NSRange(location: 11, length: 28))

        keyPress(buffer) { view.textView.insertBacktab(nil) }
        keyPress(buffer) { view.textView.insertBacktab(nil) }
        #expect(buffer.text == "func a() {\none()\n\ntwo()\n}\n")

        buffer.undoManager.undo()
        #expect(buffer.text == "func a() {\n    one()\n\n    two()\n}\n")
        buffer.undoManager.undo()
        #expect(buffer.text == "func a() {\n        one()\n\n        two()\n}\n")
        buffer.undoManager.undo()
        #expect(buffer.text == "func a() {\n    one()\n\n    two()\n}\n")
    }

    @Test func tabWithinOneLineInsertsOneStep() {
        let buffer = buffer("a\tb\n\tc\n")
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        // A selection inside one line is replaced by the step, like typing; the line is not indented.
        view.textView.setSelectedRange(NSRange(location: 2, length: 1))
        keyPress(buffer) { view.textView.insertTab(nil) }
        #expect(buffer.text == "a\t\t\n\tc\n")
        #expect(view.textView.selectedRange() == NSRange(location: 3, length: 0))
        // One undo step takes back the step and brings back what it replaced.
        buffer.undoManager.undo()
        #expect(buffer.text == "a\tb\n\tc\n")

        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        keyPress(buffer) { view.textView.insertTab(nil) }
        #expect(buffer.text == "\ta\tb\n\tc\n")
    }

    @Test func tabWithOnlyTheNewlineSelectedKeepsItSelected() {
        let buffer = buffer("foo\nbar\n")
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        view.textView.setSelectedRange(NSRange(location: 3, length: 1))
        keyPress(buffer) { view.textView.insertTab(nil) }
        #expect(buffer.text == "\tfoo\nbar\n")
        #expect(view.textView.selectedRange() == NSRange(location: 4, length: 1))

        keyPress(buffer) { view.textView.insertBacktab(nil) }
        #expect(buffer.text == "foo\nbar\n")
        #expect(view.textView.selectedRange() == NSRange(location: 3, length: 1))
    }

    @Test func shiftTabOutdentsTheCaretLineAndKeepsTheCaretOnItsCharacter() {
        let buffer = buffer("if x {\n\t\ty()\n}\n")
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        view.textView.setSelectedRange(NSRange(location: 10, length: 0))
        view.textView.insertBacktab(nil)
        #expect(buffer.text == "if x {\n\ty()\n}\n")
        #expect(view.textView.selectedRange() == NSRange(location: 9, length: 0))
        // Nothing left to take away is not an edit.
        view.textView.setSelectedRange(NSRange(location: 0, length: 0))
        view.textView.insertBacktab(nil)
        #expect(buffer.text == "if x {\n\ty()\n}\n")
    }

    @Test func returnCarriesTheIndentationOfTheLine() {
        let buffer = buffer("    let a = 1\n")
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        view.textView.setSelectedRange(NSRange(location: 13, length: 0))
        view.textView.insertNewline(nil)
        #expect(buffer.text == "    let a = 1\n    \n")
        #expect(view.textView.selectedRange() == NSRange(location: 18, length: 0))
        buffer.undoManager.undo()
        #expect(buffer.text == "    let a = 1\n")

        // Splitting inside the indentation only carries what is before the caret.
        view.textView.setSelectedRange(NSRange(location: 2, length: 0))
        view.textView.insertNewline(nil)
        #expect(buffer.text == "  \n    let a = 1\n")
    }

    @Test func savingIntoAConflictIsRefused() {
        let buffer = TextBuffer.previewSample(url: URL(filePath: "/tmp/sample.swift"), text: "a\n", edit: "b", conflict: .changed)
        let view = CodeScrollView(buffer: buffer)
        defer { view.detach() }
        view.textView.saveDocument(nil)
        #expect(buffer.refusedSaveCount == 1)
        #expect(buffer.isDirty)
    }
}
