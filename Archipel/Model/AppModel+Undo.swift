import AppKit
import ArchipelCore
import EditorUI

// Structural changes (closing and moving tabs, removing a worktree whose folder stays, renames) go on
// the main window's undo manager, which is what Edit > Undo reaches when focus is on a terminal, the
// sidebar or a tab bar. The file editor answers `undoManager` with its buffer's own, so while it has
// focus ⌘Z keeps undoing typing and never reaches these. Every action holds ids and value snapshots,
// so one recorded for something that has since gone away finds nothing and beeps.
extension AppModel {
    private var windowUndoManager: UndoManager? {
        NSApp.windows.first { Self.isMainWindow($0) }?.undoManager
    }

    /// Run from inside an undo, this lands on the redo stack, which is how each action below
    /// registers its own inverse.
    private func registerUndo(_ actionName: String, _ handler: @escaping (AppModel) -> Void) {
        guard let undo = windowUndoManager else { return }
        undo.registerUndo(withTarget: self, handler: handler)
        undo.setActionName(actionName)
    }

    // MARK: Tabs

    func registerReopen(_ closed: ClosedTab) {
        registerUndo("Close Tab") { $0.reopen(closed) }
    }

    private func reopen(_ closed: ClosedTab) {
        var reopened: Tab.ID?
        changingSelection { reopened = $0.reopen(closed) }
        guard let reopened else { return NSSound.beep() }
        // Through the normal close, so redoing it still asks about unsaved edits or a busy agent.
        registerUndo("Close Tab") { $0.close(tab: reopened) }
    }

    /// `before` is where the tab was before a move or split. A drop that left it where it was
    /// records nothing.
    func registerMove(of id: Tab.ID, from before: TabPlacement?, actionName: String) {
        guard let before, let after = workspace.placement(ofTab: id), before != after else { return }
        registerUndo(actionName) { $0.place(tab: id, at: before, actionName: actionName) }
    }

    private func place(tab id: Tab.ID, at placement: TabPlacement, actionName: String) {
        let current = workspace.placement(ofTab: id)
        var placed = false
        changingSelection { placed = $0.place(tab: id, at: placement) }
        guard placed, let current else { return NSSound.beep() }
        registerUndo(actionName) { $0.place(tab: id, at: current, actionName: actionName) }
    }

    // MARK: Worktrees

    /// Only for a worktree whose folder stayed on disk and whose git record was left alone. Anything
    /// git removed cannot be brought back by putting the row back.
    /// `comments` are the worktree's review comments as they were when it went. The status poll
    /// forgets them once the worktree is gone, so the undo carries its own copy.
    func registerRestore(_ removed: RemovedWorktree, comments: [ReviewComment] = []) {
        registerUndo("Remove Worktree") { $0.restore(removed, comments: comments) }
    }

    private func restore(_ removed: RemovedWorktree, comments: [ReviewComment]) {
        var restored = false
        changingSelection { restored = $0.restore(removed) }
        guard restored else { return NSSound.beep() }
        // Adding a comment that is still there replaces it, so this is safe before the poll ran too.
        for comment in comments { reviewComments.add(comment, in: removed.worktree.path) }
        refreshBranches()
        refreshWorktreeDiscovery()
        registerUndo("Remove Worktree") { $0.removeKeepingFolder(removed.worktree.id) }
    }

    private func removeKeepingFolder(_ id: Worktree.ID) {
        guard let removal = workspace.removal(ofWorktree: id) else { return NSSound.beep() }
        let comments = reviewComments.comments(in: removal.worktree.path)
        changingSelection { $0.removeWorktree(id: id, dismiss: true) }
        missingWorktrees.remove(id)
        refreshWorktreeDiscovery()
        registerRestore(removal, comments: comments)
    }

    // MARK: Renames

    func setTitle(ofSession id: Session.ID, to title: String, custom: Bool) {
        guard let old = workspace.session(id: id), old.title != title || old.hasCustomTitle != custom else { return }
        mutate {
            $0.updateSession(id: id) {
                $0.title = title
                $0.hasCustomTitle = custom
            }
        }
        registerUndo("Rename Session") { $0.setTitle(ofSession: id, to: old.title, custom: old.hasCustomTitle) }
    }

    func renameProject(_ id: Project.ID, to name: String) {
        guard let old = workspace.project(id: id)?.name, old != name else { return }
        mutate { $0.renameProject(id: id, to: name) }
        registerUndo("Rename Project") { $0.renameProject(id, to: old) }
    }

    func updateIsland(_ id: Island.ID, name: String, symbol: String, tint: Tint) {
        guard let old = workspace.island(id: id),
              (old.name, old.symbol, old.tint) != (name, symbol, tint)
        else { return }
        mutate {
            $0.updateIsland(id: id) { island in
                island.name = name
                island.symbol = symbol
                island.tint = tint
            }
        }
        let actionName = (old.symbol, old.tint) == (symbol, tint) ? "Rename Island" : "Edit Island"
        registerUndo(actionName) { $0.updateIsland(id, name: old.name, symbol: old.symbol, tint: old.tint) }
    }
}
