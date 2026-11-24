import ArchipelCore
import ChatUI
import Foundation
import TerminalKit

/// Files and text dropped onto a session go into its terminal as a paste, or into its chat's
/// composer: files as attachments, text into the draft.
extension AppModel {
    /// Tabs are dragged as their bare id string, which looks like any other
    /// text to a drop target. Such a string landing in a shell would be noise
    /// at best, so drops of ids the workspace knows are turned away.
    func isInternalDragPayload(_ text: String) -> Bool {
        guard let id = UUID(uuidString: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return workspace.tab(id: id) != nil
            || workspace.session(id: id) != nil
            || workspace.worktree(id: id) != nil
            || workspace.project(id: id) != nil
            || workspace.island(id: id) != nil
    }

    /// The session behind a tab if it has a terminal that can still take input, or a chat that has
    /// not ended. A chat still starting keeps what it is given for its first prompt.
    func dropTargetSession(of tab: ArchipelCore.Tab) -> Session.ID? {
        guard case .session(let id) = tab.content else { return nil }
        if let chat = chats[id] {
            if case .ended = chat.phase { return nil }
            return id
        }
        guard let terminal = terminals[id], !terminal.hasExited else { return nil }
        return id
    }

    /// Brings the tab forward first so the paste happens where the user is looking.
    func pasteFiles(_ urls: [URL], intoSessionOf tab: Tab.ID) {
        guard !urls.isEmpty, let session = showDropTarget(of: tab) else { return }
        if let chat = chats[session] {
            chat.addAttachments(urls)
        } else {
            terminals[session]?.pasteFileURLs(urls)
        }
    }

    func pasteText(_ text: String, intoSessionOf tab: Tab.ID) {
        guard !text.isEmpty, !isInternalDragPayload(text), let session = showDropTarget(of: tab) else { return }
        if let chat = chats[session] {
            // So the dropped text does not run into the last word typed.
            let separator = chat.draft.isEmpty || chat.draft.last?.isWhitespace == true ? "" : " "
            chat.draft += separator + text
        } else {
            terminals[session]?.paste(text)
        }
    }

    private func showDropTarget(of tabID: Tab.ID) -> Session.ID? {
        guard let tab = workspace.tab(id: tabID), let session = dropTargetSession(of: tab) else { return nil }
        select(tab: tabID)
        if let pane = workspace.worktree(containingTab: tabID)?.panes.first(where: { $0.tabs.contains { $0.id == tabID } }) {
            focus(pane: pane.id)
        }
        if let chat = chats[session] {
            chat.requestComposerFocus()
        } else {
            terminals[session]?.focus()
        }
        return session
    }
}
