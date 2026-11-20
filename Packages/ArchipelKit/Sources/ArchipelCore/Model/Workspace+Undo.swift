import Foundation

// Undo keeps value snapshots and ids, never live objects, so an action recorded for a worktree that
// has since gone away finds nothing to act on and reports that instead of reviving stale state.

/// Where a tab sat in its worktree. The pane is named by id, with its position kept as well so a
/// pane that disappeared when its last tab left can be rebuilt where it was.
public struct TabPlacement: Equatable, Sendable {
    public var worktreeID: Worktree.ID
    public var paneID: Pane.ID
    public var paneIndex: Int
    public var tabIndex: Int
}

/// Everything needed to bring a closed tab back. A session tab carries its session record, so the
/// session returns under the same id with its agent conversation id and resumes that conversation.
public struct ClosedTab: Equatable, Sendable {
    public var tab: Tab
    public var session: Session?
    public var placement: TabPlacement
}

/// A worktree taken out of the sidebar with its folder left on disk.
public struct RemovedWorktree: Equatable, Sendable {
    public var worktree: Worktree
    public var projectID: Project.ID
    public var index: Int
}

extension Worktree {
    func placement(ofTab id: Tab.ID) -> TabPlacement? {
        guard let (p, t) = tabLocation(id: id) else { return nil }
        return TabPlacement(worktreeID: self.id, paneID: panes[p].id, paneIndex: p, tabIndex: t)
    }

    /// Puts a tab that is in no pane into the placement's pane, rebuilding that pane if it is gone.
    /// Indexes are clamped because whatever happened since may have left fewer panes or tabs.
    mutating func insert(_ tab: Tab, at placement: TabPlacement) {
        if let p = paneIndex(id: placement.paneID) {
            panes[p].tabs.insert(tab, at: min(max(placement.tabIndex, 0), panes[p].tabs.count))
            select(tab.id, inPane: p)
        } else {
            let pane = Pane(id: placement.paneID, tabs: [tab], selectedTabID: tab.id)
            panes.insert(pane, at: min(max(placement.paneIndex, 0), panes.count))
            focusedPaneID = pane.id
        }
    }
}

extension Workspace {
    public func placement(ofTab id: Tab.ID) -> TabPlacement? {
        worktree(containingTab: id)?.placement(ofTab: id)
    }

    /// The snapshot to keep before closing the tab.
    public func closedTab(id: Tab.ID) -> ClosedTab? {
        guard let tab = tab(id: id), let placement = placement(ofTab: id) else { return nil }
        var session: Session?
        if case .session(let sessionID) = tab.content { session = self.session(id: sessionID) }
        return ClosedTab(tab: tab, session: session, placement: placement)
    }

    /// Brings a closed tab back where it was, selected, and selects its worktree. A file, diff or
    /// page that was opened again in the meantime is selected instead of shown twice. Returns the
    /// tab now showing it, or nil when its worktree is gone.
    @discardableResult
    public mutating func reopen(_ closed: ClosedTab) -> Tab.ID? {
        let worktreeID = closed.placement.worktreeID
        guard let worktree = worktree(id: worktreeID) else { return nil }
        if let session = closed.session {
            // Already back some other way; a second record would break one-tab-per-session.
            guard self.session(id: session.id) == nil else { return nil }
        } else if let existing = worktree.panes.lazy.flatMap(\.tabs).first(where: { $0.content == closed.tab.content }) {
            selectTab(id: existing.id)
            return existing.id
        }
        guard tab(id: closed.tab.id) == nil else { return nil }
        var tab = closed.tab
        // Brought back on purpose, so it should not be replaced by the next single-clicked file.
        tab.isPreview = false
        edit(worktreeID) { worktree in
            if let session = closed.session { worktree.sessions.append(session) }
            worktree.insert(tab, at: closed.placement)
        }
        selectWorktree(worktreeID)
        return tab.id
    }

    /// Moves an open tab to the placement, within its own worktree only, and selects it. False when
    /// the tab is gone or now lives in another worktree.
    @discardableResult
    public mutating func place(tab id: Tab.ID, at placement: TabPlacement) -> Bool {
        guard worktree(containingTab: id)?.id == placement.worktreeID else { return false }
        let placed = edit(placement.worktreeID) { worktree in
            guard let tab = worktree.removeTab(id: id) else { return false }
            worktree.insert(tab, at: placement)
            return true
        } ?? false
        if placed { selectWorktree(placement.worktreeID) }
        return placed
    }

    /// The snapshot to keep before removing the worktree from the sidebar.
    public func removal(ofWorktree id: Worktree.ID) -> RemovedWorktree? {
        guard let project = project(containingWorktree: id),
              let index = project.worktrees.firstIndex(where: { $0.id == id })
        else { return nil }
        return RemovedWorktree(worktree: project.worktrees[index], projectID: project.id, index: index)
    }

    /// Puts the worktree back in its place, sessions and panes included, and selects it. False when
    /// the project is gone or already lists a worktree at that path, which the user added back by hand.
    @discardableResult
    public mutating func restore(_ removed: RemovedWorktree) -> Bool {
        let sessionIDs = Set(removed.worktree.sessions.map(\.id))
        guard sessionIDs.isDisjoint(with: allSessionIDs),
              addWorktree(removed.worktree, to: removed.projectID)
        else { return false }
        updateProject(id: removed.projectID) { project in
            let worktree = project.worktrees.removeLast()
            project.worktrees.insert(worktree, at: min(max(removed.index, 0), project.worktrees.count))
        }
        return true
    }
}
