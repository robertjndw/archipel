import ArchipelCore
import ChatUI
import SwiftUI

/// A session shown as a chat. The chat only knows its conversation; this gives it the app around
/// it: tabs for files and links, Settings, the terminal for signing in, and the session's restart
/// and close.
///
/// Equatable on its inputs, and its body reads nothing from the model, only captures it: a
/// workspace change elsewhere leaves the chat, and the closures it is handed, alone.
struct ChatSessionContent: View, Equatable {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    let chat: ChatSession
    let sessionID: Session.ID
    let tabID: ArchipelCore.Tab.ID
    /// Passed in rather than asked here, so the chat does not redraw on every workspace change.
    let canSwitchToTerminal: Bool
    /// The agent's own mark, which lives in the app's asset catalog where the chat cannot load it.
    let agentSymbolName: String

    nonisolated static func == (lhs: ChatSessionContent, rhs: ChatSessionContent) -> Bool {
        lhs.chat === rhs.chat && lhs.sessionID == rhs.sessionID && lhs.tabID == rhs.tabID
            && lhs.canSwitchToTerminal == rhs.canSwitchToTerminal && lhs.agentSymbolName == rhs.agentSymbolName
    }

    var body: some View {
        ChatView(session: chat, actions: actions, agentSymbol: Image(symbol: agentSymbolName))
    }

    private var actions: ChatViewActions {
        let model = model
        let sessionID = sessionID
        let tabID = tabID
        let openSettings = openSettings
        // Switched without asking: the button only shows while the chat waits on a sign-in,
        // which the confirmation would wrongly call work in progress.
        var signInInTerminal: (@MainActor () -> Void)?
        if canSwitchToTerminal {
            signInInTerminal = { model.setInterface(.terminal, for: sessionID) }
        }
        return ChatViewActions(
            // The editor has no way to be told a line yet, so the file opens at its top.
            openFile: { url, _ in
                model.openFile(url, in: model.workspace.worktree(containing: sessionID)?.id, preview: false)
            },
            openLink: { model.openChatLink($0, from: sessionID) },
            signInInTerminal: signInInTerminal,
            openAgentSettings: {
                SettingsView.select(.agents)
                openSettings()
            },
            restart: { model.restartSession(sessionID) },
            close: { model.close(tab: tabID) },
            userInteracted: { model.acknowledge(sessionID) }
        )
    }
}

#if DEBUG
#Preview("Finished") {
    ChatSessionContent(chat: .preview(.finished), sessionID: PreviewFixtures.claudeSessionID, tabID: UUID(), canSwitchToTerminal: true, agentSymbolName: "claude.logo")
        .environment(AppModel.chatPreview())
        .frame(width: 700, height: 500)
}

#Preview("Awaiting Permission, Dark") {
    ChatSessionContent(chat: .preview(.awaitingPermission), sessionID: PreviewFixtures.claudeSessionID, tabID: UUID(), canSwitchToTerminal: true, agentSymbolName: "claude.logo")
        .environment(AppModel.chatPreview(.awaitingPermission))
        .frame(width: 700, height: 500)
        .preferredColorScheme(.dark)
}

#Preview("Sign In Required") {
    ChatSessionContent(chat: .preview(.signInRequired), sessionID: PreviewFixtures.claudeSessionID, tabID: UUID(), canSwitchToTerminal: true, agentSymbolName: "claude.logo")
        .environment(AppModel.chatPreview(.signInRequired))
        .frame(width: 700, height: 500)
}

#Preview("Installing") {
    ChatSessionContent(chat: .preview(.installing), sessionID: PreviewFixtures.claudeSessionID, tabID: UUID(), canSwitchToTerminal: true, agentSymbolName: "claude.logo")
        .environment(AppModel.chatPreview(.installing))
        .frame(width: 700, height: 500)
}
#endif
