#if DEBUG
import ACPKit
import SwiftUI

// One preview per state the chat can be in. Preview sessions have no agent behind them, so
// sending and the settings do nothing, and Send stays disabled.

private let previewSize = CGSize(width: 900, height: 700)

@MainActor
private func chatPreview(_ session: ChatSession, width: CGFloat = previewSize.width, terminal: Bool = true) -> some View {
    var actions = ChatViewActions()
    if terminal { actions.signInInTerminal = {} }
    return ChatView(session: session, actions: actions)
        .frame(width: width, height: previewSize.height)
}

#Preview("Empty") {
    chatPreview(.preview(.empty))
}

#Preview("Empty, Dark") {
    chatPreview(.preview(.empty))
        .preferredColorScheme(.dark)
}

#Preview("Finished") {
    chatPreview(.preview(.finished))
}

#Preview("Finished, Dark") {
    chatPreview(.preview(.finished))
        .preferredColorScheme(.dark)
}

#Preview("Finished, Narrow") {
    chatPreview(.preview(.finished), width: 480)
}

#Preview("Streaming") {
    chatPreview(.preview(.streaming))
}

#Preview("Streaming, Live") {
    LiveStreamingPreview()
}

#Preview("Working, a Minute In") {
    let session = ChatSession.preview(.streaming)
    session.viewState.setTurnClock(TurnClock(turn: 0, elapsed: 72))
    return chatPreview(session)
}

#Preview("Working Status") {
    VStack(alignment: .leading, spacing: 0) {
        WorkingStatusLine(phrase: WorkingStatus.working, anchor: .now)
        WorkingStatusLine(phrase: WorkingStatus.thinking, anchor: .now.addingTimeInterval(-8))
        WorkingStatusLine(phrase: "Reading ChatTranscriptView.swift", anchor: .now.addingTimeInterval(-72))
        WorkingStatusLine(phrase: "Running swift build -c release --product archipel-hook", anchor: .now.addingTimeInterval(-3840))
        WorkingStatusLine(phrase: WorkingStatus.stopping, anchor: nil)
    }
    .padding(20)
    .frame(width: 360, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
}

#Preview("Find") {
    let session = ChatSession.preview(.finished)
    session.viewState.find.present()
    session.viewState.find.query = "password"
    return chatPreview(session)
}

#Preview("Find, Dark") {
    let session = ChatSession.preview(.finished)
    session.viewState.find.present()
    session.viewState.find.query = "login"
    return chatPreview(session)
        .preferredColorScheme(.dark)
}

#Preview("Find, Narrow, Not Found") {
    let session = ChatSession.preview(.finished)
    session.viewState.find.present()
    session.viewState.find.query = "logout"
    return chatPreview(session, width: 480)
}

#Preview("Awaiting Permission") {
    chatPreview(.preview(.awaitingPermission))
}

#Preview("Awaiting Permission, Dark") {
    chatPreview(.preview(.awaitingPermission))
        .preferredColorScheme(.dark)
}

#Preview("Awaiting Permission, Narrow") {
    chatPreview(.preview(.awaitingPermission), width: 480)
}

#Preview("Plan Approval") {
    chatPreview(ChatPreviewScenes.planApproval)
}

#Preview("Command Permission, Narrow") {
    chatPreview(ChatPreviewScenes.commandPermission, width: 480)
}

#Preview("Background Work") {
    chatPreview(ChatPreviewScenes.backgroundWork)
}

#Preview("Tool Calls Expanded") {
    ChatTranscriptView(
        session: .preview(.finished), actions: ChatViewActions(),
        expanded: ["fold:message-1", "message-1", "tool:sample-read", "tool:sample-search", "tool:sample-edit", "tool:sample-test"]
    )
    .background(Color(nsColor: .textBackgroundColor))
    .frame(width: previewSize.width, height: previewSize.height)
}

#Preview("Plan") {
    VStack(alignment: .leading, spacing: 12) {
        PlanView(entries: ChatPreviewSamples.plan, isExpanded: true)
        PlanView(entries: ChatPreviewSamples.plan)
    }
    .padding(20)
    .frame(width: 520, alignment: .leading)
    .background(Color(nsColor: .textBackgroundColor))
}

#Preview("Queued") {
    let session = ChatSession.preview(.streaming)
    session.queuedPrompts = [
        QueuedPrompt(text: "Then run the tests and fix whatever fails"),
        QueuedPrompt(text: "Also update the changelog, and mention that the old flag keeps working for one more release"),
    ]
    return chatPreview(session, width: 560)
}

#Preview("Installing") {
    chatPreview(.preview(.installing))
}

#Preview("Sign In Required") {
    chatPreview(.preview(.signInRequired))
}

#Preview("Node Missing") {
    chatPreview(.preview(.nodeMissing))
}

#Preview("Could Not Start") {
    chatPreview(ChatPreviewScenes.couldNotStart)
}

#Preview("Ended") {
    chatPreview(.preview(.ended))
}

#Preview("Ended, Dark") {
    chatPreview(.preview(.ended))
        .preferredColorScheme(.dark)
}

/// Types a reply out on a timer, to watch the transcript follow it and to see that streaming
/// text does not make the rows above it move.
private struct LiveStreamingPreview: View {
    @State private var session = ChatPreviewScenes.waitingForReply

    private static let reply = ChatPreviewSamples.reply + "\n\n" + (1...12).map {
        "\($0). Another line of the answer, long enough to wrap in a narrow pane and to push the transcript past the end of the pane."
    }.joined(separator: "\n")

    var body: some View {
        chatPreview(session)
            .task {
                var remaining = Substring(Self.reply)
                while !remaining.isEmpty {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                    let chunk = remaining.prefix(Int.random(in: 2...9))
                    remaining = remaining.dropFirst(chunk.count)
                    session.transcript.apply(.agentMessageChunk(ContentChunk(content: .text(String(chunk)), messageId: "live")))
                }
                session.transcript.endTurn(.endTurn)
                session.isTurnRunning = false
            }
    }
}

/// Situations beyond `ChatSession.preview(_:)` that only the views need to see.
@MainActor
private enum ChatPreviewScenes {
    /// The prompt is sent and nothing has come back yet.
    static var waitingForReply: ChatSession {
        var transcript = ChatTranscript()
        transcript.apply(SessionSetup(modes: ChatPreviewSamples.modes, configOptions: ChatPreviewSamples.configOptions))
        transcript.appendUserPrompt([.text(ChatPreviewSamples.userPrompt)])
        return ChatSession(previewAgentName: "Claude Code", phase: .ready, transcript: transcript, isTurnRunning: true)
    }

    /// A turn that is over while a dev server and a subagent it started are still running.
    static var backgroundWork: ChatSession {
        var transcript = ChatTranscript()
        transcript.apply(SessionSetup(modes: ChatPreviewSamples.modes, configOptions: ChatPreviewSamples.configOptions))
        transcript.appendUserPrompt([.text("Start the dev server and have someone look into the flaky login test.")])
        var server = ToolCall(
            toolCallId: "sample-server", title: "npm run dev", kind: .execute, status: .completed,
            terminalOutput: "Command running in background with ID: b1."
        )
        server.toolName = "Bash"
        server.backgroundTaskId = "b1"
        var subagent = ToolCall(toolCallId: "sample-subagent", title: "Investigate the flaky login test", kind: .think, status: .completed)
        subagent.toolName = "Agent"
        subagent.startedBackgroundSubagent = true
        var search = ToolCall(toolCallId: "sample-step-1", title: "Search for \"testLogin\"", kind: .search, status: .completed)
        search.parentToolCallId = subagent.toolCallId
        var read = ToolCall(
            toolCallId: "sample-step-2", title: "Read Tests/LoginTests.swift", kind: .read, status: .inProgress,
            locations: [ToolCallLocation(path: "/Users/me/Projects/Acme/Tests/LoginTests.swift")]
        )
        read.parentToolCallId = subagent.toolCallId
        transcript.apply(.toolCall(server))
        transcript.apply(.toolCall(subagent))
        transcript.apply(.agentMessageChunk(ContentChunk(content: .text("The dev server is up, and a subagent is looking into the test."), messageId: "sample-started")))
        transcript.apply(.toolCall(search))
        transcript.apply(.toolCall(read))
        return ChatSession(previewAgentName: "Claude Code", phase: .ready, transcript: transcript)
    }

    /// Claude asking to leave plan mode, with wordy options and two more requests queued.
    static var planApproval: ChatSession {
        let call = ToolCall(
            toolCallId: "sample-plan", title: "Ready to code?", kind: .switchMode, status: .pending,
            content: [.content(.text("""
            ## Plan

            1. Tighten `isFormValid` so an empty password is rejected.
            2. Add `testEmptyPasswordIsInvalid`.
            3. Run the login tests.

            No public API changes.
            """))]
        )
        let request = ChatPermissionRequest(
            id: .int(1),
            options: [
                PermissionOption(optionId: "a", name: "Yes, and auto-accept edits", kind: .allowAlways),
                PermissionOption(optionId: "b", name: "Yes, and manually approve edits", kind: .allowOnce),
                PermissionOption(optionId: "c", name: "No, keep planning", kind: .rejectOnce),
            ],
            toolCall: call, requestedToolCall: ToolCallUpdate(toolCallId: call.toolCallId)
        )
        return ChatSession(
            previewAgentName: "Claude Code", phase: .ready, transcript: ChatPreviewSamples.pendingEditConversation,
            permissionRequests: [request, ChatPreviewSamples.editPermissionRequest], isTurnRunning: true
        )
    }

    /// Codex asking to run a command, with its sentence-long option names.
    static var commandPermission: ChatSession {
        let call = ToolCall(
            toolCallId: "sample-command", title: "Run command", kind: .execute, status: .pending,
            rawInput: ["command": ["bash", "-lc", "rm -rf build && swift build -c release --product archipel-hook"]]
        )
        let request = ChatPermissionRequest(
            id: .int(1),
            options: [
                PermissionOption(optionId: "allow_once", name: "Yes", kind: .allowOnce),
                PermissionOption(optionId: "allow_for_session", name: "Yes, and don't ask again for this command", kind: .allowAlways),
                PermissionOption(optionId: "cancel", name: "No, and tell Codex what to do differently", kind: .rejectOnce),
            ],
            toolCall: call, requestedToolCall: ToolCallUpdate(toolCallId: call.toolCallId)
        )
        return ChatSession(
            previewAgentName: "Codex", phase: .ready, transcript: ChatPreviewSamples.pendingEditConversation,
            permissionRequests: [request], isTurnRunning: true
        )
    }

    static var couldNotStart: ChatSession {
        let failure = ChatFailure(
            reason: .couldNotStart,
            title: "Could Not Start Claude Code",
            message: "Claude Code quit while starting.",
            details: "Error: Cannot find module '/Users/me/.archipel/agents/claude/dist/index.js'\n    at Module._resolveFilename (node:internal/modules/cjs/loader:1145:15)"
        )
        return ChatSession(previewAgentName: "Claude Code", phase: .failed(failure))
    }
}
#endif
