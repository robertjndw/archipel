import AgentKit
import AppKit
import ArchipelCore
import EditorUI

/// Small conveniences for the sidebar and the island switcher.
extension AppModel {
    var defaultAgent: AgentDefinition {
        AgentDefinition.builtIn(id: settings.defaultAgentID) ?? .claude
    }

    /// The order of the File menu and the palette: the default agent gets ⌘T, the others follow.
    var agentsInMenuOrder: [AgentDefinition] {
        let defaultAgent = defaultAgent
        return [defaultAgent] + AgentDefinition.builtIns.filter { $0.id != defaultAgent.id }
    }

    /// False for an agent that is not installed. The default agent is let through regardless: ⌘T
    /// should never be a dead key, and the session it opens says what is missing.
    func canStartSession(with agent: AgentDefinition) -> Bool {
        isInstalled(agent) || agent.id == defaultAgent.id
    }

    /// Title of the "Needs Me" toggle in the menu bar and the palette.
    var needsMeFilterTitle: String { showsOnlyNeedsMe ? "Show All in Sidebar" : "Show Only What Needs Me" }
    /// Filled while the filter is on.
    var needsMeFilterSymbol: String { showsOnlyNeedsMe ? "bell.fill" : "bell" }

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
            focusedSessionID: workspace.focusedSessionID(in: worktree.id)
        )
    }

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
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
