import AppKit
import ArchipelCore
import EditorUI
import TerminalKit

extension AppModel {
    // MARK: Keyboard focus

    /// Moves the focus to the next (1) or previous (-1) pane and puts the keyboard into the tab it
    /// shows. Does nothing with a single pane.
    func focusAdjacentPane(offset: Int) {
        guard let pane = selectedWorktree?.paneID(adjacentToFocused: offset) else { return }
        // A text field would otherwise keep the keys, the same as when a tab is clicked.
        endTextFieldEditing()
        focus(pane: pane)
        switch focusedTab?.content {
        case .session, .file:
            focusFocusedTabSoon()
        case .diff, .web, nil:
            guard let window = NSApp.keyWindow, Self.isMainWindow(window), window.attachedSheet == nil else { return }
            if focusFocusedDiff(in: window) { return }
            // A web page or an empty pane has nothing to hand the keyboard to by name. It still
            // has to leave the pane behind, or typing would go on in a terminal that no longer
            // looks focused.
            window.makeFirstResponder(nil)
        }
    }

    /// Gives the keyboard to the diff the focused pane shows. The pane is on screen already, so
    /// where it reported its frame is where the diff is.
    private func focusFocusedDiff(in window: NSWindow) -> Bool {
        guard case .diff? = focusedTab?.content, let pane = selectedWorktree?.focusedPaneID,
              let frame = paneFrames[pane], let content = window.contentView
        else { return false }
        // Pane frames have their origin at the top left, AppKit's window at the bottom left.
        let rect = NSRect(x: frame.minX, y: content.bounds.height - frame.maxY, width: frame.width, height: frame.height)
        return DiffFocus.focusDiff(in: window, within: rect)
    }

    /// For when the focused pane was closed from under the keyboard: the focus moved to another
    /// pane, whose tab was on screen all along and so does not ask for the keys by itself.
    /// Only when the keyboard was really left behind. A close by mouse while a text field is being
    /// edited leaves the field its keys.
    func focusFocusedTabIfKeyboardIsLost() {
        Task { @MainActor [weak self] in
            // The closed pane's view, and the first responder with it, goes with SwiftUI's update.
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, let window = NSApp.windows.first(where: { Self.isMainWindow($0) }),
                  window.attachedSheet == nil, self.isOverlayPresented?() != true,
                  // A window whose first responder left it falls back to itself.
                  window.firstResponder == nil || window.firstResponder === window
            else { return }
            if let id = focusedSessionID {
                terminals[id]?.focus()
            } else if case .file(let url)? = focusedTab?.content {
                EditorFocus.request(url)
            } else {
                _ = focusFocusedDiff(in: window)
            }
        }
    }

    // MARK: Find

    /// Steps through the matches of the focused terminal's scrollback search, for the Find menu.
    /// False when that terminal has no search open, and the menu's action belongs to whoever has
    /// the keyboard.
    func stepTerminalSearch(forward: Bool) -> Bool {
        guard Self.isMainWindow(NSApp.keyWindow), let id = focusedSessionID,
              let search = terminals[id]?.search, search.isActive
        else { return false }
        if forward { search.next() } else { search.previous() }
        return true
    }

    /// A terminal that comes on screen leaves the keyboard with a text field that is being edited,
    /// so that a session which took a moment to start does not pull the user out of a field they
    /// went to meanwhile. Going to another tab is the user leaving the field, though, and that has
    /// to end the editing, or the commit message would keep the keys after a click on a tab.
    func endTextFieldEditing() {
        // Not under the palette: its own field is the one being edited, and it hands the keyboard
        // on itself when it closes.
        guard isOverlayPresented?() != true,
              let window = NSApp.windows.first(where: { Self.isMainWindow($0) }),
              (window.firstResponder as? NSText)?.isFieldEditor == true
        else { return }
        window.makeFirstResponder(nil)
    }

    // MARK: Widths

    /// One share of the width per pane of the selected worktree, as the divider was just left.
    func setPaneWidthShares(_ shares: [Double], in worktreeID: Worktree.ID) {
        guard let current = workspace.worktree(id: worktreeID)?.paneWidthShares, current.count == shares.count else { return }
        let total = shares.reduce(0, +)
        // A drag that ends where it began, or a split that only just evened itself out, is no
        // reason to write the workspace.
        guard total > 0, zip(current, shares).contains(where: { abs($0 - $1 / total) > 0.002 }) else { return }
        mutate { $0.setPaneWidthShares(shares, in: worktreeID) }
    }
}
