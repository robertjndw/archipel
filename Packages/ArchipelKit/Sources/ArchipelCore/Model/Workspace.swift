import Foundation

public struct Workspace: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 3

    public var schemaVersion: Int
    public var islands: [Island]
    public var selectedIslandID: Island.ID?
    public var selectedWorktreeIDByIsland: [Island.ID: Worktree.ID]

    public init(
        schemaVersion: Int = Workspace.currentSchemaVersion,
        islands: [Island],
        selectedIslandID: Island.ID? = nil,
        selectedWorktreeIDByIsland: [Island.ID: Worktree.ID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.islands = islands
        self.selectedIslandID = selectedIslandID ?? islands.first?.id
        self.selectedWorktreeIDByIsland = selectedWorktreeIDByIsland
    }

    private struct LegacyKeys: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
        static let selectedSessionIDByWorktree = LegacyKeys(stringValue: "selectedSessionIDByWorktree")
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        let islands = try c.decode([Island].self, forKey: .islands)
        self.islands = islands
        // A missing or stale selection falls back to the first island, as in a fresh workspace, so
        // nothing above the model has to guess which island is meant.
        let selectedIslandID = try c.decodeIfPresent(Island.ID.self, forKey: .selectedIslandID)
        self.selectedIslandID = selectedIslandID.flatMap { id in islands.contains { $0.id == id } ? id : nil }
            ?? islands.first?.id
        selectedWorktreeIDByIsland = try c.decode([Island.ID: Worktree.ID].self, forKey: .selectedWorktreeIDByIsland)

        // Version 2 remembered one selected session per worktree; it becomes the synthesized pane's selected tab.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent([Worktree.ID: Session.ID].self, forKey: .selectedSessionIDByWorktree) ?? [:]
        for (worktreeID, sessionID) in legacy {
            updateWorktree(id: worktreeID) { worktree in
                guard worktree.panes.count == 1, let tab = worktree.tabShowing(sessionID) else { return }
                worktree.panes[0].selectedTabID = tab.id
            }
        }
    }

    /// One default island, because the sidebar needs somewhere to put the first project.
    public init() {
        self.init(islands: [Island(name: "Personal", symbol: "person.crop.circle", tint: .blue)])
    }

    // MARK: Lookups

    public var allWorktrees: [Worktree] {
        islands.flatMap { $0.projects.flatMap(\.worktrees) }
    }

    public var allSessionIDs: Set<Session.ID> {
        Set(islands.lazy.flatMap(\.projects).flatMap(\.worktrees).flatMap(\.sessions).map(\.id))
    }

    public var allSessions: [Session] {
        allWorktrees.flatMap(\.sessions)
    }

    public func island(id: Island.ID) -> Island? {
        islands.first { $0.id == id }
    }

    public func project(id: Project.ID) -> Project? {
        locate(projectID: id).map { islands[$0.island].projects[$0.project] }
    }

    public func worktree(id: Worktree.ID) -> Worktree? {
        locate(worktreeID: id).map { islands[$0.island].projects[$0.project].worktrees[$0.worktree] }
    }

    public func session(id: Session.ID) -> Session? {
        guard let loc = locate(sessionID: id) else { return nil }
        return islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions[loc.session]
    }

    public func pane(id: Pane.ID) -> Pane? {
        allWorktrees.lazy.flatMap(\.panes).first { $0.id == id }
    }

    public func tab(id: Tab.ID) -> Tab? {
        allWorktrees.lazy.flatMap(\.panes).flatMap(\.tabs).first { $0.id == id }
    }

    public func tab(showing sessionID: Session.ID) -> Tab? {
        allWorktrees.lazy.compactMap { $0.tabShowing(sessionID) }.first
    }

    public func worktree(containingPane paneID: Pane.ID) -> Worktree? {
        allWorktrees.first { $0.panes.contains { $0.id == paneID } }
    }

    public func worktree(containingTab tabID: Tab.ID) -> Worktree? {
        allWorktrees.first { $0.tabLocation(id: tabID) != nil }
    }

    public func pane(containingTab tabID: Tab.ID) -> Pane? {
        allWorktrees.lazy.flatMap(\.panes).first { $0.tabs.contains { $0.id == tabID } }
    }

    public func island(containing sessionID: Session.ID) -> Island? {
        locate(sessionID: sessionID).map { islands[$0.island] }
    }

    public func project(containing sessionID: Session.ID) -> Project? {
        locate(sessionID: sessionID).map { islands[$0.island].projects[$0.project] }
    }

    public func worktree(containing sessionID: Session.ID) -> Worktree? {
        guard let loc = locate(sessionID: sessionID) else { return nil }
        return islands[loc.island].projects[loc.project].worktrees[loc.worktree]
    }

    public func project(containingWorktree worktreeID: Worktree.ID) -> Project? {
        locate(worktreeID: worktreeID).map { islands[$0.island].projects[$0.project] }
    }

    public func island(containingWorktree worktreeID: Worktree.ID) -> Island? {
        locate(worktreeID: worktreeID).map { islands[$0.island] }
    }

    public func island(containingProject projectID: Project.ID) -> Island? {
        locate(projectID: projectID).map { islands[$0.island] }
    }

    // MARK: Islands

    @discardableResult
    public mutating func addIsland(name: String, symbol: String = "square.stack.3d.up", tint: Tint = .blue) -> Island.ID {
        let island = Island(name: name, symbol: symbol, tint: tint)
        islands.append(island)
        selectedIslandID = island.id
        return island.id
    }

    public mutating func updateIsland(id: Island.ID, _ change: (inout Island) -> Void) {
        guard let i = islands.firstIndex(where: { $0.id == id }) else { return }
        change(&islands[i])
    }

    public mutating func renameIsland(id: Island.ID, to name: String) {
        updateIsland(id: id) { $0.name = name }
    }

    /// Returns false when the island is unknown or is the last one left.
    @discardableResult
    public mutating func removeIsland(id: Island.ID) -> Bool {
        guard islands.count > 1, let i = islands.firstIndex(where: { $0.id == id }) else { return false }
        islands.remove(at: i)
        if selectedIslandID == id || selectedIslandID == nil {
            selectedIslandID = islands[min(i, islands.count - 1)].id
        }
        pruneSelections()
        return true
    }

    /// `index` is the position in the array after the island has been taken out.
    public mutating func moveIsland(id: Island.ID, to index: Int) {
        guard let i = islands.firstIndex(where: { $0.id == id }) else { return }
        let island = islands.remove(at: i)
        islands.insert(island, at: min(max(index, 0), islands.count))
    }

    // MARK: Projects

    @discardableResult
    public mutating func addProject(_ project: Project, to islandID: Island.ID) -> Bool {
        guard let i = islands.firstIndex(where: { $0.id == islandID }) else { return false }
        islands[i].projects.append(project)
        return true
    }

    public mutating func updateProject(id: Project.ID, _ change: (inout Project) -> Void) {
        guard let loc = locate(projectID: id) else { return }
        change(&islands[loc.island].projects[loc.project])
    }

    public mutating func renameProject(id: Project.ID, to name: String) {
        updateProject(id: id) { $0.name = name }
    }

    public mutating func removeProject(id: Project.ID) {
        guard let loc = locate(projectID: id) else { return }
        islands[loc.island].projects.remove(at: loc.project)
        pruneSelections()
    }

    /// Moves within an island or to another one. `index` is the position among the destination's
    /// projects after the project has been taken out; nil appends.
    public mutating func moveProject(id: Project.ID, to islandID: Island.ID, at index: Int? = nil) {
        guard let dest = islands.firstIndex(where: { $0.id == islandID }),
              let loc = locate(projectID: id) else { return }
        let source = islands[loc.island].id
        let project = islands[loc.island].projects.remove(at: loc.project)
        // The old island may have remembered one of this project's worktrees. It moves on to the
        // project that took this one's place rather than showing nothing while it still has some.
        if dest != loc.island, let selected = selectedWorktreeIDByIsland[source],
           project.worktrees.contains(where: { $0.id == selected }) {
            let remaining = islands[loc.island].projects
            let neighbour = remaining.isEmpty ? nil : remaining[min(loc.project, remaining.count - 1)]
            selectedWorktreeIDByIsland[source] = (neighbour?.worktrees.first(where: \.isMain) ?? neighbour?.worktrees.first)?.id
        }
        let count = islands[dest].projects.count
        islands[dest].projects.insert(project, at: min(max(index ?? count, 0), count))
        pruneSelections()
    }

    // MARK: Worktrees

    /// Returns false, changing nothing, when the project is unknown or already has a worktree at that path.
    @discardableResult
    public mutating func addWorktree(_ worktree: Worktree, to projectID: Project.ID) -> Bool {
        guard let loc = locate(projectID: projectID) else { return false }
        let key = Project.worktreeKey(worktree.path)
        guard !islands[loc.island].projects[loc.project].worktrees.contains(where: { Project.worktreeKey($0.path) == key })
        else { return false }
        var worktree = worktree
        worktree.normalize()
        islands[loc.island].projects[loc.project].worktrees.append(worktree)
        islands[loc.island].projects[loc.project].dismissedWorktreePaths.remove(key)
        selectWorktree(worktree.id)
        return true
    }

    public mutating func updateWorktree(id: Worktree.ID, _ change: (inout Worktree) -> Void) {
        edit(id, change)
    }

    /// The main worktree is the project folder itself, so it cannot be removed. With `dismiss` the
    /// path is remembered so detection does not offer the folder straight back.
    public mutating func removeWorktree(id: Worktree.ID, dismiss: Bool = false) {
        guard let loc = locate(worktreeID: id) else { return }
        let project = islands[loc.island].projects[loc.project]
        guard !project.worktrees[loc.worktree].isMain else { return }
        let islandID = islands[loc.island].id
        let removed = islands[loc.island].projects[loc.project].worktrees.remove(at: loc.worktree)
        if dismiss {
            islands[loc.island].projects[loc.project].dismissedWorktreePaths.insert(Project.worktreeKey(removed.path))
        }
        if selectedWorktreeIDByIsland[islandID] == id {
            selectedWorktreeIDByIsland[islandID] = project.worktrees.first(where: \.isMain)?.id
        }
        pruneSelections()
    }

    /// Stops detection from suggesting a worktree the user does not want in the sidebar.
    public mutating func dismissWorktree(path: URL, in projectID: Project.ID) {
        updateProject(id: projectID) { $0.dismissedWorktreePaths.insert(Project.worktreeKey(path)) }
    }

    public mutating func restoreDismissedWorktrees(in projectID: Project.ID) {
        updateProject(id: projectID) { $0.dismissedWorktreePaths.removeAll() }
    }

    // MARK: Sessions and tabs

    /// Adds the record and a tab for it, selected and focused, since users add a session to start using it.
    /// Does not change the selected worktree or island.
    @discardableResult
    public mutating func addSession(_ session: Session, to worktreeID: Worktree.ID, pane: Pane.ID? = nil) -> Bool {
        edit(worktreeID) { $0.addSession(session, pane: pane) } != nil
    }

    public mutating func updateSession(id: Session.ID, _ change: (inout Session) -> Void) {
        guard let loc = locate(sessionID: id) else { return }
        change(&islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions[loc.session])
    }

    public mutating func removeSession(id: Session.ID) {
        guard let loc = locate(sessionID: id) else { return }
        let worktreeID = islands[loc.island].projects[loc.project].worktrees[loc.worktree].id
        edit(worktreeID) { worktree in
            if let tab = worktree.tabShowing(id) { worktree.removeTab(id: tab.id) }
            worktree.sessions.removeAll { $0.id == id }
        }
    }

    /// Previews replace the pane's existing preview tab; an equal tab anywhere in the worktree is reused.
    /// Returns nil for session content, which only `addSession` creates, or an unknown worktree.
    @discardableResult
    public mutating func openTab(_ content: TabContent, in worktreeID: Worktree.ID, pane: Pane.ID? = nil, preview: Bool) -> Tab.ID? {
        edit(worktreeID) { $0.openTab(content, pane: pane, preview: preview) } ?? nil
    }

    public mutating func pinTab(id: Tab.ID) {
        guard let worktreeID = worktree(containingTab: id)?.id else { return }
        edit(worktreeID) { worktree in
            if let (p, t) = worktree.tabLocation(id: id) { worktree.panes[p].tabs[t].isPreview = false }
        }
    }

    /// Closing a session tab also removes the session record.
    public mutating func closeTab(id: Tab.ID) {
        guard let worktreeID = worktree(containingTab: id)?.id else { return }
        edit(worktreeID) { worktree in
            guard let tab = worktree.removeTab(id: id), case .session(let sessionID) = tab.content else { return }
            worktree.sessions.removeAll { $0.id == sessionID }
        }
    }

    /// Selects the tab in its pane, focuses that pane, and selects the owning worktree and island.
    public mutating func selectTab(id: Tab.ID) {
        guard let worktreeID = worktree(containingTab: id)?.id else { return }
        edit(worktreeID) { worktree in
            if let (p, _) = worktree.tabLocation(id: id) { worktree.select(id, inPane: p) }
        }
        selectWorktree(worktreeID)
    }

    public mutating func focusPane(id: Pane.ID) {
        guard let worktreeID = worktree(containingPane: id)?.id else { return }
        edit(worktreeID) { $0.focusedPaneID = id }
    }

    /// Reorders within a pane or moves across panes of one worktree; `index` is the position in the
    /// destination after the tab has been taken out. Panes of different worktrees are a no-op.
    public mutating func moveTab(id: Tab.ID, toPane paneID: Pane.ID, at index: Int? = nil) {
        guard let worktreeID = worktree(containingTab: id)?.id,
              worktree(containingPane: paneID)?.id == worktreeID else { return }
        edit(worktreeID) { $0.moveTab(id: id, toPane: paneID, at: index) }
    }

    /// Moves the tab into a new pane right after its current one. Nil when it is the pane's only tab.
    @discardableResult
    public mutating func splitTab(id: Tab.ID) -> Pane.ID? {
        guard let worktreeID = worktree(containingTab: id)?.id else { return nil }
        return edit(worktreeID) { $0.splitTab(id: id) } ?? nil
    }

    /// The sessions shown by each pane's selected tab, in pane order.
    public func visibleSessionIDs(in worktreeID: Worktree.ID) -> [Session.ID] {
        worktree(id: worktreeID)?.panes.compactMap { sessionID(of: $0.selectedTab) } ?? []
    }

    public func focusedSessionID(in worktreeID: Worktree.ID) -> Session.ID? {
        sessionID(of: worktree(id: worktreeID)?.focusedPane?.selectedTab)
    }

    // MARK: Selection

    public mutating func selectIsland(_ id: Island.ID) {
        guard islands.contains(where: { $0.id == id }) else { return }
        selectedIslandID = id
    }

    /// Selects the worktree and switches to the island that owns it.
    public mutating func selectWorktree(_ id: Worktree.ID) {
        guard let loc = locate(worktreeID: id) else { return }
        let islandID = islands[loc.island].id
        selectedIslandID = islandID
        selectedWorktreeIDByIsland[islandID] = id
    }

    /// Selects the session's tab (focusing its pane), plus that worktree and island.
    public mutating func selectSession(_ id: Session.ID) {
        guard let tab = tab(showing: id) else { return }
        selectTab(id: tab.id)
    }

    public var selectedWorktreeID: Worktree.ID? {
        selectedIslandID.flatMap { selectedWorktreeIDByIsland[$0] }
    }

    // MARK: Private

    private func sessionID(of tab: Tab?) -> Session.ID? {
        guard case .session(let id) = tab?.content else { return nil }
        return id
    }

    /// Runs `body` on the worktree and restores its invariants afterwards. Nil when the worktree is unknown.
    @discardableResult
    mutating func edit<T>(_ id: Worktree.ID, _ body: (inout Worktree) -> T) -> T? {
        guard let loc = locate(worktreeID: id) else { return nil }
        let result = body(&islands[loc.island].projects[loc.project].worktrees[loc.worktree])
        islands[loc.island].projects[loc.project].worktrees[loc.worktree].normalize()
        return result
    }

    private struct Location { var island = 0, project = 0, worktree = 0, session = 0 }

    private func locate(projectID: Project.ID) -> Location? {
        for i in islands.indices {
            if let p = islands[i].projects.firstIndex(where: { $0.id == projectID }) {
                return Location(island: i, project: p)
            }
        }
        return nil
    }

    private func locate(worktreeID: Worktree.ID) -> Location? {
        for i in islands.indices {
            for p in islands[i].projects.indices {
                if let w = islands[i].projects[p].worktrees.firstIndex(where: { $0.id == worktreeID }) {
                    return Location(island: i, project: p, worktree: w)
                }
            }
        }
        return nil
    }

    private func locate(sessionID: Session.ID) -> Location? {
        for i in islands.indices {
            for p in islands[i].projects.indices {
                for w in islands[i].projects[p].worktrees.indices {
                    if let s = islands[i].projects[p].worktrees[w].sessions.firstIndex(where: { $0.id == sessionID }) {
                        return Location(island: i, project: p, worktree: w, session: s)
                    }
                }
            }
        }
        return nil
    }

    /// Drops remembered selections that no longer point at something that exists where it is remembered.
    private mutating func pruneSelections() {
        selectedWorktreeIDByIsland = selectedWorktreeIDByIsland.filter { islandID, worktreeID in
            island(containingWorktree: worktreeID)?.id == islandID
        }
    }
}
