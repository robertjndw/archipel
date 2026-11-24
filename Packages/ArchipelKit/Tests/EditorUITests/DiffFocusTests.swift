import AppKit
import Testing
@testable import EditorUI

@MainActor
struct DiffFocusTests {
    private func window(with panes: [DiffPaneView]) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        // One level down, the way a diff sits inside its container.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(container)
        for (index, pane) in panes.enumerated() {
            pane.frame = NSRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100)
            container.addSubview(pane)
        }
        return window
    }

    @Test func theDiffInsideTheRectTakesTheKeyboard() {
        let here = DiffPaneView(role: .unified)
        let elsewhere = DiffPaneView(role: .unified)
        let window = window(with: [here, elsewhere])

        #expect(DiffFocus.focusDiff(in: window, within: NSRect(x: 0, y: 0, width: 90, height: 300)))
        #expect(window.firstResponder === here)
        #expect(DiffFocus.focusDiff(in: window, within: NSRect(x: 110, y: 0, width: 80, height: 300)))
        #expect(window.firstResponder === elsewhere)
    }

    @Test func sideBySideTheNewSideTakesTheKeyboard() {
        let old = DiffPaneView(role: .old)
        let new = DiffPaneView(role: .new)
        let window = window(with: [old, new])

        #expect(DiffFocus.focusDiff(in: window, within: NSRect(x: 0, y: 0, width: 200, height: 300)))
        #expect(window.firstResponder === new)
    }

    @Test func aRectWithoutADiffLeavesTheKeyboardAlone() {
        let pane = DiffPaneView(role: .unified)
        let window = window(with: [pane])
        let before = window.firstResponder

        #expect(!DiffFocus.focusDiff(in: window, within: NSRect(x: 250, y: 0, width: 100, height: 300)))
        #expect(window.firstResponder === before)

        pane.isHidden = true
        #expect(!DiffFocus.focusDiff(in: window, within: NSRect(x: 0, y: 0, width: 400, height: 300)))
    }
}
