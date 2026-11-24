import AppKit

/// Hands the keyboard to a diff that is on screen, for a host that moves its focus there from the
/// keyboard. The diff then takes Cmd-C and the scrolling keys without a click first.
///
/// Unlike `EditorFocus` there is nothing to wait for and no file to name: the host knows where
/// the diff is, and two tabs can show the same one.
@MainActor
public enum DiffFocus {
    /// Makes the diff inside `rect` first responder, which is in window coordinates. Side by
    /// side, the new side gets the keys. False when no diff is there.
    @discardableResult
    public static func focusDiff(in window: NSWindow, within rect: NSRect) -> Bool {
        guard let content = window.contentView, let pane = panes(under: content, within: rect).last else { return false }
        return window.makeFirstResponder(pane)
    }

    private static func panes(under view: NSView, within rect: NSRect) -> [DiffPaneView] {
        if view.isHidden { return [] }
        if let pane = view as? DiffPaneView {
            return pane.convert(pane.visibleRect, to: nil).intersects(rect) ? [pane] : []
        }
        return view.subviews.flatMap { panes(under: $0, within: rect) }
    }
}
