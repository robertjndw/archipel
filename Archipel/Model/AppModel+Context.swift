import AgentKit
import ArchipelCore
import Foundation

extension AppModel {
    /// Claude's status line sends the context window on every redraw. Only a request going out or
    /// coming back changes it, so the rest are dropped before they re-render the status bar.
    func recordContext(_ context: SessionContext, for id: Session.ID) {
        let previous = sessionContexts[id]
        guard previous != context else { return }
        // A new transcript is a new conversation, and the old one's cache says nothing about it.
        let isNewTranscript = previous?.transcriptPath != context.transcriptPath
        if isNewTranscript { promptCaches[id] = nil }
        sessionContexts[id] = context
        // The cache is hidden while the agent works, and the turn-finished event reads the
        // transcript anyway. No point re-reading up to 1 MB on every request in between.
        if isNewTranscript || !activity(for: id).isBusy { refreshPromptCache(for: id) }
    }

    /// Reads when the session's prompt cache goes cold from the end of its transcript, which can
    /// run to many megabytes, so off the main actor.
    func refreshPromptCache(for id: Session.ID) {
        guard let path = sessionContexts[id]?.transcriptPath else { return }
        promptCacheReads[id]?.cancel()
        promptCacheReads[id] = Task {
            let url = URL(fileURLWithPath: path)
            let state = await Task.detached(priority: .utility) { ClaudeTranscript.cacheState(at: url) }.value
            // A newer read was started meanwhile, or the session went away.
            guard !Task.isCancelled, sessionContexts[id]?.transcriptPath == path else { return }
            promptCacheReads[id] = nil
            // A transcript that could not be read says nothing new, so what was known stays.
            if let state, state != promptCaches[id] { promptCaches[id] = state }
        }
    }

    /// The model the session runs on. A chat knows it from its agent. A terminal has what Claude's
    /// status line last reported, or else what the launch arguments asked for.
    func modelName(for id: Session.ID) -> String? {
        if workspace.session(id: id)?.effectiveInterface == .acp { return chats[id]?.modelName }
        return sessionModels[id] ?? launchedModels[id]
    }

    func forgetContext(of id: Session.ID) {
        promptCacheReads.removeValue(forKey: id)?.cancel()
        if sessionContexts[id] != nil { sessionContexts[id] = nil }
        if promptCaches[id] != nil { promptCaches[id] = nil }
    }
}
