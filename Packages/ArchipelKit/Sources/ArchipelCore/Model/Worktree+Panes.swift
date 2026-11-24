import Foundation

// The pane logic lives on Worktree so each operation sees one worktree's panes and sessions together.
extension Worktree {
    /// Restores the invariants after decoding or after a caller edited `sessions` or `panes` directly.
    mutating func normalize() {
        let known = Set(sessions.map(\.id))
        var shown = Set<Session.ID>()
        for p in panes.indices {
            panes[p].tabs = panes[p].tabs.compactMap { tab in
                guard case .session(let id) = tab.content else { return tab }
                guard known.contains(id), shown.insert(id).inserted else { return nil }
                var tab = tab
                tab.isPreview = false
                return tab
            }
        }
        if panes.isEmpty { panes = [Pane()] }

        let target = focusedPaneIndex ?? 0
        for session in sessions where !shown.contains(session.id) {
            panes[target].tabs.append(Tab(content: .session(session.id)))
        }

        // An empty pane only survives as the sole pane.
        if panes.contains(where: { !$0.tabs.isEmpty }) { panes.removeAll { $0.tabs.isEmpty } }
        for p in panes.indices where !panes[p].tabs.contains(where: { $0.id == panes[p].selectedTabID }) {
            panes[p].selectedTabID = panes[p].tabs.first?.id
        }
        if !panes.contains(where: { $0.id == focusedPaneID }) { focusedPaneID = panes[0].id }
        // A share only means something next to the others, so a pane that lost its neighbours'
        // shares (a hand-edited file, a pane rebuilt by undo) takes everyone back to equal widths.
        if !panes.allSatisfy({ $0.widthShare.map { $0.isFinite && $0 > 0 } ?? false }) { resetPaneWidths() }
    }

    mutating func resetPaneWidths() {
        for p in panes.indices where panes[p].widthShare != nil { panes[p].widthShare = nil }
    }

    /// Each pane's fraction of the width in pane order, adding up to 1. Equal fractions while no
    /// divider has been dragged since the panes last changed.
    public var paneWidthShares: [Double] {
        let stored = panes.compactMap(\.widthShare)
        let total = stored.reduce(0, +)
        guard stored.count == panes.count, total > 0 else {
            return panes.map { _ in 1 / Double(max(panes.count, 1)) }
        }
        // Written already adding up to 1; only a file edited by hand needs the division.
        return abs(total - 1) < 1e-9 ? stored : stored.map { $0 / total }
    }

    /// Ignored unless there is one positive share per pane.
    mutating func setPaneWidthShares(_ shares: [Double]) {
        let total = shares.reduce(0, +)
        guard shares.count == panes.count, shares.allSatisfy({ $0.isFinite && $0 > 0 }) else { return }
        for p in panes.indices { panes[p].widthShare = shares[p] / total }
    }

    /// The pane `offset` places after the focused one, wrapping around. Nil with a single pane,
    /// which has nowhere to go.
    public func paneID(adjacentToFocused offset: Int) -> Pane.ID? {
        guard panes.count > 1, let current = focusedPaneIndex else { return nil }
        let count = panes.count
        return panes[((current + offset) % count + count) % count].id
    }

    private var focusedPaneIndex: Int? {
        panes.firstIndex { $0.id == focusedPaneID } ?? (panes.isEmpty ? nil : 0)
    }

    func paneIndex(id: Pane.ID) -> Int? {
        panes.firstIndex { $0.id == id }
    }

    func tabLocation(id: Tab.ID) -> (pane: Int, tab: Int)? {
        tabLocation { $0.id == id }
    }

    private func tabLocation(where match: (Tab) -> Bool) -> (pane: Int, tab: Int)? {
        for p in panes.indices {
            if let t = panes[p].tabs.firstIndex(where: match) { return (p, t) }
        }
        return nil
    }

    func tabShowing(_ sessionID: Session.ID) -> Tab? {
        panes.lazy.flatMap(\.tabs).first { $0.content == .session(sessionID) }
    }

    mutating func addSession(_ session: Session, pane paneID: Pane.ID?) {
        sessions.append(session)
        let p = paneID.flatMap(paneIndex(id:)) ?? focusedPaneIndex ?? 0
        let tab = Tab(content: .session(session.id))
        panes[p].tabs.append(tab)
        select(tab.id, inPane: p)
    }

    mutating func openTab(_ content: TabContent, pane paneID: Pane.ID?, preview: Bool) -> Tab.ID? {
        if case .session = content { return nil }
        if let (p, t) = tabLocation(where: { $0.content == content }) {
            if !preview { panes[p].tabs[t].isPreview = false }
            select(panes[p].tabs[t].id, inPane: p)
            return panes[p].tabs[t].id
        }
        let p = paneID.flatMap(paneIndex(id:)) ?? focusedPaneIndex ?? 0
        let id: Tab.ID
        if preview, let t = panes[p].tabs.firstIndex(where: \.isPreview) {
            panes[p].tabs[t].content = content
            id = panes[p].tabs[t].id
        } else {
            let tab = Tab(content: content, isPreview: preview)
            panes[p].tabs.append(tab)
            id = tab.id
        }
        select(id, inPane: p)
        return id
    }

    mutating func select(_ tabID: Tab.ID, inPane p: Int) {
        panes[p].selectedTabID = tabID
        focusedPaneID = panes[p].id
    }

    /// Takes the tab out, picks the next (else previous) tab if it was selected, and drops its pane
    /// when that leaves it empty and another pane remains.
    @discardableResult
    mutating func removeTab(id: Tab.ID) -> Tab? {
        guard let (p, t) = tabLocation(id: id) else { return nil }
        let wasSelected = panes[p].selectedTab?.id == id
        let wasFocused = focusedPane?.id == panes[p].id
        let tab = panes[p].tabs.remove(at: t)
        if wasSelected {
            let tabs = panes[p].tabs
            panes[p].selectedTabID = tabs.isEmpty ? nil : tabs[min(t, tabs.count - 1)].id
        }
        if panes[p].tabs.isEmpty, panes.count > 1 {
            panes.remove(at: p)
            if wasFocused { focusedPaneID = panes[min(p, panes.count - 1)].id }
        }
        return tab
    }

    mutating func moveTab(id: Tab.ID, toPane destID: Pane.ID, at index: Int?) {
        guard let (sp, t) = tabLocation(id: id), let dp = paneIndex(id: destID) else { return }
        if sp == dp {
            let tab = panes[sp].tabs.remove(at: t)
            panes[sp].tabs.insert(tab, at: min(max(index ?? panes[sp].tabs.count, 0), panes[sp].tabs.count))
            select(id, inPane: sp)
            return
        }
        guard let tab = removeTab(id: id), let dest = paneIndex(id: destID) else { return }
        let count = panes[dest].tabs.count
        panes[dest].tabs.insert(tab, at: min(max(index ?? count, 0), count))
        select(id, inPane: dest)
    }

    mutating func splitTab(id: Tab.ID) -> Pane.ID? {
        guard let (p, _) = tabLocation(id: id), panes[p].tabs.count > 1 else { return nil }
        let sourceID = panes[p].id
        guard let tab = removeTab(id: id), let source = paneIndex(id: sourceID) else { return nil }
        let pane = Pane(tabs: [tab], selectedTabID: tab.id)
        panes.insert(pane, at: source + 1)
        focusedPaneID = pane.id
        return pane.id
    }
}
