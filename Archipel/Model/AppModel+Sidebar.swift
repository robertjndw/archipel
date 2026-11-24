import AgentKit
import AppKit
import ArchipelCore
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
    /// Focuses whatever the focused tab shows, its terminal or a file's editor, so the user can type
    /// without clicking first. The short wait lets SwiftUI swap in the new tab's view.
    func focusFocusedTabSoon() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, NSApp.keyWindow?.attachedSheet == nil else { return }
            if let id = focusedSessionID {
                terminals[id]?.focus()
            } else if case .file(let url)? = focusedTab?.content {
                EditorFocus.request(url)
            }
        }
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
    /// The worktrees picked together in the sidebar, in sidebar order. Empty unless there are at
    /// least two, so callers can fall back to the selected worktree.
    var multiSelectedWorktrees: [Worktree] {
        guard sidebarSelection.count > 1 else { return [] }
        return workspace.allWorktrees.filter { sidebarSelection.contains($0.id) }
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
