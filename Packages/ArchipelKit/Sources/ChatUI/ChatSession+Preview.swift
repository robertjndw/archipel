import ACPKit
import Foundation

extension ChatSession {
    /// The situations a chat view has to handle, for `preview(_:agentName:)`.
    public enum PreviewState: Sendable, CaseIterable {
        /// Ready, nothing said yet.
        case empty
        /// A finished turn with every kind of content.
        case finished
        /// Mid-turn: streaming text and a running tool call.
        case streaming
        /// Waiting on a permission request for an edit.
        case awaitingPermission
        /// Downloading the chat adapter.
        case installing
        /// Signed out, with one sign-in method of each kind.
        case signInRequired
        /// Node.js is missing.
        case nodeMissing
        /// The agent crashed after a finished turn.
        case ended
    }

    /// A session showing `state`, with sample content and no process.
    public static func preview(_ state: PreviewState, agentName: String = "Claude Code") -> ChatSession {
        let session = previewSession(state, agentName: agentName)
        // Typing an @ in a live preview offers the sample project's files.
        session.fileIndex = WorktreeFileIndex(root: URL(filePath: "/Users/me/Projects/Acme", directoryHint: .isDirectory), files: previewFiles)
        return session
    }

    /// The sample project the preview conversations are about.
    static let previewFiles = [
        ".github/workflows/ci.yml",
        ".gitignore",
        "Package.swift",
        "README.md",
        "Sources/App/AcmeApp.swift",
        "Sources/Login/LoginView.swift",
        "Sources/Login/LoginViewModel.swift",
        "Sources/Login/PasswordField.swift",
        "Sources/Networking/Session.swift",
        "Sources/Networking/SessionStore.swift",
        "Tests/LoginTests/LoginViewModelTests.swift",
        "Tests/NetworkingTests/SessionStoreTests.swift",
    ]

    private static func previewSession(_ state: PreviewState, agentName: String) -> ChatSession {
        let info = Implementation(name: "claude-agent-acp", title: agentName, version: "0.110.0")
        switch state {
        case .empty:
            var transcript = ChatTranscript()
            transcript.apply(SessionSetup(modes: ChatPreviewSamples.modes, configOptions: ChatPreviewSamples.configOptions))
            return ChatSession(previewAgentName: agentName, phase: .ready, transcript: transcript, agentInfo: info)
        case .finished:
            return ChatSession(previewAgentName: agentName, phase: .ready, transcript: ChatPreviewSamples.finishedConversation, agentInfo: info)
        case .streaming:
            return ChatSession(
                previewAgentName: agentName, phase: .ready, transcript: ChatPreviewSamples.streamingConversation,
                isTurnRunning: true, agentInfo: info
            )
        case .awaitingPermission:
            return ChatSession(
                previewAgentName: agentName, phase: .ready, transcript: ChatPreviewSamples.pendingEditConversation,
                permissionRequests: [ChatPreviewSamples.editPermissionRequest], isTurnRunning: true, agentInfo: info
            )
        case .installing:
            return ChatSession(previewAgentName: agentName, phase: .starting(.installing(agentName: agentName, fraction: 0.42)))
        case .signInRequired:
            // One of each kind so both buttons show; real agents offer one kind or the other.
            let failure = ChatFailure(
                reason: .signInRequired(
                    agentMethods: [AuthMethod(id: "api-key", name: "Use an API Key", type: .agent)],
                    terminalMethods: [AuthMethod(id: "claude-ai-login", name: "Claude Account", type: .terminal, args: ["--cli", "auth", "login"])]
                ),
                title: "Sign In to \(agentName)",
                message: "\(agentName) needs you to sign in before it can answer."
            )
            var transcript = ChatTranscript()
            transcript.appendUserPrompt([.text(ChatPreviewSamples.userPrompt)])
            transcript.endTurn(nil)
            return ChatSession(previewAgentName: agentName, phase: .failed(failure), transcript: transcript, agentInfo: info)
        case .nodeMissing:
            let failure = ChatFailure(
                reason: .nodeMissing,
                title: "Node.js Is Required",
                message: "\(agentName) needs Node.js to run as a chat. Install it from nodejs.org or with Homebrew, then try again."
            )
            return ChatSession(previewAgentName: agentName, phase: .failed(failure))
        case .ended:
            let ending = ChatEnding(
                exitCode: 1, isClean: false,
                message: "\(agentName) quit unexpectedly (exit code 1).",
                details: "Error: ENOENT: no such file or directory, open '/Users/me/.claude/settings.json'\n    at Object.openSync (node:fs:573:18)"
            )
            return ChatSession(previewAgentName: agentName, phase: .ended(ending), transcript: ChatPreviewSamples.finishedConversation, agentInfo: info)
        }
    }
}
