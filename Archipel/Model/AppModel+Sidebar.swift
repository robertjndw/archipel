import AgentKit
import AppKit
import ArchipelCore
import ChatUI
import EditorUI

/// Small conveniences for the sidebar and the island switcher.
extension AppModel {
    /// The agents New Session offers, in registry order. Sessions of the others keep running.
    var enabledAgents: [any AgentAdapter] {
        agentRegistry.adapters.filter { settings.isEnabled($0.id) }
    }

    /// Settings keep the default enabled, but the stored id can still point at a disabled agent,
    /// for instance one given on the command line. ⌘T then starts the first enabled agent instead.
    var defaultAgent: any AgentAdapter {
        let chosen = agentRegistry.adapter(id: settings.defaultAgentID)
        if let chosen, settings.isEnabled(chosen.id) { return chosen }
        return enabledAgents.first ?? chosen ?? ClaudeAdapter()
    }

    /// The order of the File menu and the palette: the default agent gets ⌘T, the others follow.
    var agentsInMenuOrder: [any AgentAdapter] {
        let defaultAgent = defaultAgent
        return [defaultAgent] + enabledAgents.filter { $0.id != defaultAgent.id }
    }

    /// The presets the File menu and the palette offer, grouped by agent in menu order. Presets of
    /// agents that take no arguments, like the shell, are left out.
    var presetsInMenuOrder: [(agent: any AgentAdapter, preset: LaunchPreset)] {
        agentsInMenuOrder.filter(\.capabilities.acceptsPrompts).flatMap { agent in
            settings.launchPresets.filter { $0.agentID == agent.id }.map { (agent: agent, preset: $0) }
        }
    }

    /// False for an agent that is not installed. The default agent is let through regardless: ⌘T
    /// should never be a dead key, and the session it opens says what is missing.
    func canStartSession(with agent: any AgentAdapter) -> Bool {
        isInstalled(agent) || agent.id == defaultAgent.id
    }

    /// Title of the "Needs Me" toggle in the menu bar and the palette.
    var needsMeFilterTitle: String { showsOnlyNeedsMe ? "Show All in Sidebar" : "Show Only What Needs Me" }
    /// Filled while the filter is on.
    var needsMeFilterSymbol: String { showsOnlyNeedsMe ? "bell.fill" : "bell" }

    /// Turning the filter on also jumps to the next session that needs the user, unless the
    /// focused one already does, since they may be answering it. Turning it off never jumps.
    func toggleNeedsMeFilter() {
        guard !showsOnlyNeedsMe else {
            showsOnlyNeedsMe = false
            return
        }
        // Filter before selecting, so the selection pins the row we jump to.
        showsOnlyNeedsMe = true
        if let focused = focusedSessionID, activities[focused]?.needsMe == true { return }
        selectNextNeedingAttention()
    }

    /// The island before or after the selected one, wrapping around.
    func selectAdjacentIsland(offset: Int) {
        let islands = workspace.islands
        guard islands.count > 1, let index = islands.firstIndex(where: { $0.id == workspace.selectedIslandID }) else { return }
        select(island: islands[(index + offset + islands.count) % islands.count].id)
    }

    /// True while at least one project of the selected island shows its worktrees.
    var hasExpandedProjects: Bool {
        selectedIsland?.projects.contains(where: \.isExpanded) ?? false
    }

    func setAllProjects(expanded: Bool) {
        let ids = selectedIsland?.projects.map(\.id) ?? []
        mutate { workspace in
            for id in ids { workspace.updateProject(id: id) { $0.isExpanded = expanded } }
        }
        // The status poll skipped the projects that were collapsed.
        if expanded { refreshGitStatus(lookingUpPullRequests: true) }
    }

    /// What the sidebar lists while it shows only what needs the user: islands and projects in their
    /// usual order, with the worktrees that wait on the user and the selected one if it was just opened.
    func needsMeGroups() -> [NeedsMeIsland] {
        var wanted = worktreesNeedingAttention(in: workspace, activities: activities)
        if let pin = needsMePin, pin == selectedWorktree?.id { wanted.insert(pin) }
        return workspace.islands.compactMap { island in
            let projects = island.projects.compactMap { project -> NeedsMeProject? in
                let worktrees = project.worktrees.filter { wanted.contains($0.id) }
                return worktrees.isEmpty ? nil : NeedsMeProject(project: project, worktrees: worktrees)
            }
            return projects.isEmpty ? nil : NeedsMeIsland(island: island, projects: projects)
        }
    }

    func islandSummaries() -> [Island.ID: AttentionSummary] {
        islandAttention
    }

    func sessionRows(for worktree: Worktree) -> [SessionRowContent] {
        SessionRowContent.rows(
            for: worktree,
            activities: activities,
            focusedSessionID: workspace.focusedSessionID(in: worktree.id),
            agentOverrides: agentOverrides
        )
    }

    func revealInFinder(_ url: URL) {
        revealInFinder([url])
    }

    func revealInFinder(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    /// Terminal.app rather than the user's default terminal: there is no API that names the default
    /// one, and Terminal is always there.
    func openInTerminal(_ folder: URL) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension AppModel {
    /// Focuses whatever the focused tab shows, its terminal, its chat's composer or a file's editor,
    /// so the user can type without clicking first. The short wait lets SwiftUI swap in the new tab's view.
    func focusFocusedTabSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, NSApp.keyWindow?.attachedSheet == nil else { return }
            if let id = focusedSessionID {
                if let chat = chats[id] {
                    chat.requestComposerFocus()
                } else {
                    terminals[id]?.focus()
                }
            } else if case .file(let url)? = focusedTab?.content {
                EditorFocus.request(url)
            }
        }
    }
}

// MARK: Removing islands and projects

/// What the confirmations say, shared by the context menus and the palette.
extension AppModel {
    func deletionMessage(for island: Island) -> String {
        island.projects.count == 1
            ? "Its project is removed from Archipel and its sessions are closed. Nothing is deleted from disk."
            : "Its \(island.projects.count) projects are removed from Archipel and their sessions are closed. Nothing is deleted from disk."
    }

    func removalMessage(for project: Project) -> String {
        let sessions = project.worktrees.flatMap(\.sessions)
        let working = sessions.count { activity(for: $0.id).hasWorkInFlight }
        let closing = switch working {
        case 0: sessions.isEmpty ? "" : " and its sessions are closed"
        case 1: " and its sessions are closed, including an agent that is still running"
        default: " and its sessions are closed, including \(working) agents that are still running"
        }
        return "The project is removed from Archipel\(closing). Nothing is deleted from disk."
    }

    /// An island with nothing in it goes without asking, as from its context menu.
    func requestDeletion(of island: Island) {
        guard workspace.islands.count > 1 else { return }
        if island.projects.isEmpty {
            removeIsland(island.id)
        } else if readyForSheet() {
            islandAwaitingDeletion = island
        }
    }
}

// MARK: Order

/// Islands and projects are put in order by hand. Worktrees are not: they follow git.
extension AppModel {
    /// Where the island is in the switcher, for disabling Move Left and Move Right at the ends.
    func canMoveIsland(_ id: Island.ID, by offset: Int) -> Bool {
        guard let index = workspace.islands.firstIndex(where: { $0.id == id }) else { return false }
        return workspace.islands.indices.contains(index + offset)
    }

    func moveIsland(_ id: Island.ID, by offset: Int) {
        mutate { $0.moveIsland(id: id, by: offset) }
    }

    func moveIsland(_ id: Island.ID, before target: Island.ID?) {
        mutate { $0.moveIsland(id: id, before: target) }
    }

    func canMoveProject(_ id: Project.ID, by offset: Int) -> Bool {
        guard let projects = workspace.island(containingProject: id)?.projects,
              let index = projects.firstIndex(where: { $0.id == id })
        else { return false }
        return projects.indices.contains(index + offset)
    }

    func moveProject(_ id: Project.ID, by offset: Int) {
        mutate { $0.moveProject(id: id, by: offset) }
    }

    /// A project header dropped on another one of the same island takes its place, so dragging
    /// down lands below the target and dragging up lands above it. False for anything else.
    @discardableResult
    func moveProject(_ id: Project.ID, onto target: Project.ID) -> Bool {
        guard id != target, let island = workspace.island(containingProject: target),
              workspace.island(containingProject: id)?.id == island.id,
              let index = island.projects.firstIndex(where: { $0.id == target })
        else { return false }
        mutate { $0.moveProject(id: id, to: island.id, at: index) }
        return true
    }
}

struct NeedsMeIsland: Identifiable {
    let island: Island
    let projects: [NeedsMeProject]
    var id: Island.ID { island.id }
}

struct NeedsMeProject: Identifiable {
    let project: Project
    let worktrees: [Worktree]
    var id: Project.ID { project.id }
}

// MARK: Multi-selection

/// Several worktrees acted on together. Identifiable so it can drive `.sheet(item:)`.
struct WorktreeBatch: Identifiable {
    let id = UUID()
    let worktrees: [Worktree]
}

extension AppModel {
    /// The worktree rows the sidebar lists right now, in its order. The "Needs Me" list has rows
    /// from every island and ignores collapsed projects; the normal one shows the selected island's
    /// expanded projects.
    var sidebarRows: [Worktree] {
        if showsOnlyNeedsMe { return needsMeGroups().flatMap { $0.projects.flatMap(\.worktrees) } }
        return (selectedIsland?.projects ?? []).filter(\.isExpanded).flatMap(\.worktrees)
    }

    func isListedInSidebar(_ id: Worktree.ID) -> Bool {
        sidebarRows.contains { $0.id == id }
    }

    /// The worktrees picked together in the sidebar, in sidebar order. Empty unless at least two of
    /// them still have a row, so callers can fall back to the selected worktree.
    var multiSelectedWorktrees: [Worktree] {
        guard sidebarSelection.count > 1 else { return [] }
        let picked = sidebarRows.filter { sidebarSelection.contains($0.id) }
        return picked.count > 1 ? picked : []
    }

    /// Drops picked worktrees that were removed. A lone survivor is not a batch any more and goes
    /// too, so its row gets its own menu back.
    func pruneSidebarSelection() {
        guard !sidebarSelection.isEmpty else { return }
        let live = sidebarSelection.filter { workspace.worktree(id: $0) != nil }
        let kept = live.count > 1 ? live : []
        if kept != sidebarSelection { sidebarSelection = kept }
    }

    /// The part of the multi-selection that can be removed. The primary checkout is the project
    /// itself, so it is left out rather than blocking the rest.
    var removableMultiSelection: [Worktree] {
        multiSelectedWorktrees.filter { !$0.isMain }
    }

    func requestRemoval(of worktrees: [Worktree]) {
        guard !worktrees.isEmpty, readyForSheet() else { return }
        if worktrees.count == 1 {
            worktreeAwaitingRemoval = worktrees[0]
        } else {
            worktreesAwaitingRemoval = WorktreeBatch(worktrees: worktrees)
        }
    }
}
