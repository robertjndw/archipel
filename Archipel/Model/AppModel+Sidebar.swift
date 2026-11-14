import AgentKit
import AppKit
import ArchipelCore

/// Small conveniences for the sidebar and the island switcher.
extension AppModel {
    var defaultAgent: AgentDefinition {
        AgentDefinition.builtIn(id: settings.defaultAgentID) ?? .claude
    }

    func islandSummaries() -> [Island.ID: AttentionSummary] {
        Dictionary(uniqueKeysWithValues: workspace.islands.map { ($0.id, attentionSummary(of: $0, activities: activities)) })
    }

    func sessionRows(for worktree: Worktree) -> [SessionRowContent] {
        SessionRowContent.rows(
            for: worktree,
            activities: activities,
            focusedSessionID: workspace.focusedSessionID(in: worktree.id)
        )
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
