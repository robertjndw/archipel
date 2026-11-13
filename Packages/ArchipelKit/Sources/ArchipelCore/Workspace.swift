import Foundation

public struct Workspace: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var islands: [Island]
    public var selectedIslandID: Island.ID?
    public var selectedWorktreeIDByIsland: [Island.ID: Worktree.ID]
    public var selectedSessionIDByWorktree: [Worktree.ID: Session.ID]

    public init(
        schemaVersion: Int = Workspace.currentSchemaVersion,
        islands: [Island],
        selectedIslandID: Island.ID? = nil,
        selectedWorktreeIDByIsland: [Island.ID: Worktree.ID] = [:],
        selectedSessionIDByWorktree: [Worktree.ID: Session.ID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.islands = islands
        self.selectedIslandID = selectedIslandID ?? islands.first?.id
        self.selectedWorktreeIDByIsland = selectedWorktreeIDByIsland
        self.selectedSessionIDByWorktree = selectedSessionIDByWorktree
    }

    /// One default island, because the sidebar needs somewhere to put the first project.
    public init() {
        self.init(islands: [Island(name: "Personal", symbol: "person.crop.circle", tint: .blue)])
    }

    // MARK: Lookups

    public var allWorktrees: [Worktree] {
        islands.flatMap { $0.projects.flatMap(\.worktrees) }
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
        let project = islands[loc.island].projects.remove(at: loc.project)
        let count = islands[dest].projects.count
        islands[dest].projects.insert(project, at: min(max(index ?? count, 0), count))
        // The old island may have remembered one of this project's worktrees.
        pruneSelections()
    }

    // MARK: Worktrees

    /// Returns false, changing nothing, when the project is unknown or already has a worktree at that path.
    @discardableResult
    public mutating func addWorktree(_ worktree: Worktree, to projectID: Project.ID) -> Bool {
        guard let loc = locate(projectID: projectID) else { return false }
        let path = worktree.path.standardizedFileURL
        guard !islands[loc.island].projects[loc.project].worktrees.contains(where: { $0.path.standardizedFileURL == path })
        else { return false }
        islands[loc.island].projects[loc.project].worktrees.append(worktree)
        selectWorktree(worktree.id)
        return true
    }

    public mutating func updateWorktree(id: Worktree.ID, _ change: (inout Worktree) -> Void) {
        guard let loc = locate(worktreeID: id) else { return }
        change(&islands[loc.island].projects[loc.project].worktrees[loc.worktree])
    }

    /// The main worktree is the project folder itself, so it cannot be removed.
    public mutating func removeWorktree(id: Worktree.ID) {
        guard let loc = locate(worktreeID: id) else { return }
        let project = islands[loc.island].projects[loc.project]
        guard !project.worktrees[loc.worktree].isMain else { return }
        let islandID = islands[loc.island].id
        islands[loc.island].projects[loc.project].worktrees.remove(at: loc.worktree)
        if selectedWorktreeIDByIsland[islandID] == id {
            selectedWorktreeIDByIsland[islandID] = project.worktrees.first(where: \.isMain)?.id
        }
        pruneSelections()
    }

    // MARK: Sessions

    /// Also selects the new session as its worktree's tab, since users add a session to start using it.
    @discardableResult
    public mutating func addSession(_ session: Session, to worktreeID: Worktree.ID) -> Bool {
        guard let loc = locate(worktreeID: worktreeID) else { return false }
        islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions.append(session)
        selectedSessionIDByWorktree[worktreeID] = session.id
        return true
    }

    public mutating func updateSession(id: Session.ID, _ change: (inout Session) -> Void) {
        guard let loc = locate(sessionID: id) else { return }
        change(&islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions[loc.session])
    }

    public mutating func removeSession(id: Session.ID) {
        guard let loc = locate(sessionID: id) else { return }
        let worktree = islands[loc.island].projects[loc.project].worktrees[loc.worktree]
        islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions.remove(at: loc.session)
        if selectedSessionIDByWorktree[worktree.id] == id {
            let remaining = worktree.sessions.filter { $0.id != id }
            // Same index is the next tab; clamping falls back to the previous one at the end.
            selectedSessionIDByWorktree[worktree.id] = remaining.isEmpty
                ? nil : remaining[min(loc.session, remaining.count - 1)].id
        }
    }

    /// Reorders tabs within the session's worktree. `index` is the position after the session has
    /// been taken out, clamped to the valid range.
    public mutating func moveSession(id: Session.ID, toIndex index: Int) {
        guard let loc = locate(sessionID: id) else { return }
        let session = islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions.remove(at: loc.session)
        let count = islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions.count
        islands[loc.island].projects[loc.project].worktrees[loc.worktree].sessions.insert(session, at: min(max(index, 0), count))
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

    /// Selects the session as its worktree's tab, plus that worktree and island.
    public mutating func selectSession(_ id: Session.ID) {
        guard let worktree = worktree(containing: id) else { return }
        selectWorktree(worktree.id)
        selectedSessionIDByWorktree[worktree.id] = id
    }

    public var selectedWorktreeID: Worktree.ID? {
        selectedIslandID.flatMap { selectedWorktreeIDByIsland[$0] }
    }

    /// The remembered tab if it still exists, otherwise the worktree's first session.
    public func selectedSessionID(in worktreeID: Worktree.ID) -> Session.ID? {
        guard let worktree = worktree(id: worktreeID) else { return nil }
        if let stored = selectedSessionIDByWorktree[worktreeID], worktree.sessions.contains(where: { $0.id == stored }) {
            return stored
        }
        return worktree.sessions.first?.id
    }

    // MARK: Private

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
        selectedSessionIDByWorktree = selectedSessionIDByWorktree.filter { worktreeID, sessionID in
            worktree(containing: sessionID)?.id == worktreeID
        }
    }
}
