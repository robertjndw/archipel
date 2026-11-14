import ArchipelCore
import Foundation
import TerminalKit

/// Files and text dropped onto a session go into its terminal as a paste.
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

    /// The session behind a tab if it has a terminal that can still take input.
    func dropTargetSession(of tab: ArchipelCore.Tab) -> Session.ID? {
        guard case .session(let id) = tab.content, let terminal = terminals[id], !terminal.hasExited else { return nil }
        return id
    }

    /// Brings the tab forward first so the paste happens where the user is looking.
    func pasteFiles(_ urls: [URL], intoSessionOf tab: Tab.ID) {
        guard !urls.isEmpty, let terminal = showTerminal(of: tab) else { return }
        terminal.pasteFileURLs(urls)
    }

    func pasteText(_ text: String, intoSessionOf tab: Tab.ID) {
        guard !text.isEmpty, !isInternalDragPayload(text), let terminal = showTerminal(of: tab) else { return }
        terminal.paste(text)
    }

    private func showTerminal(of tabID: Tab.ID) -> TerminalSession? {
        guard let tab = workspace.tab(id: tabID), let session = dropTargetSession(of: tab), let terminal = terminals[session] else { return nil }
        select(tab: tabID)
        if let pane = workspace.worktree(containingTab: tabID)?.panes.first(where: { $0.tabs.contains { $0.id == tabID } }) {
            focus(pane: pane.id)
        }
        terminal.focus()
        return terminal
    }
}
