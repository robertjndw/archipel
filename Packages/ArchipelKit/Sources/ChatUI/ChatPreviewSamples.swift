import ACPKit
import Foundation

/// A short, realistic coding conversation for previews and the app's preview model.
public enum ChatPreviewSamples {
    public static let userPrompt = "The login form accepts an empty password. Can you fix that and add a test?"

    public static let thought = """
    The validation lives in LoginViewModel. I should check how it decides the form is valid, \
    then tighten the password check and cover it with a test in LoginViewModelTests.
    """

    public static let readCall = ToolCall(
        toolCallId: "sample-read",
        title: "Read Sources/Login/LoginViewModel.swift",
        kind: .read,
        status: .completed,
        locations: [ToolCallLocation(path: "/Users/me/Projects/Acme/Sources/Login/LoginViewModel.swift", line: 18)]
    )

    public static let searchCall = ToolCall(
        toolCallId: "sample-search",
        title: "Search for \"isFormValid\"",
        kind: .search,
        status: .completed,
        content: [.content(.text("Sources/Login/LoginViewModel.swift:24\nSources/Login/LoginView.swift:61"))]
    )

    public static let editCall = ToolCall(
        toolCallId: "sample-edit",
        title: "Edit Sources/Login/LoginViewModel.swift",
        kind: .edit,
        status: .completed,
        content: [.diff(
            path: "/Users/me/Projects/Acme/Sources/Login/LoginViewModel.swift",
            oldText: """
            var isFormValid: Bool {
                !email.isEmpty
            }
            """,
            newText: """
            var isFormValid: Bool {
                !email.isEmpty && !password.trimmingCharacters(in: .whitespaces).isEmpty
            }
            """
        )],
        locations: [ToolCallLocation(path: "/Users/me/Projects/Acme/Sources/Login/LoginViewModel.swift", line: 24)]
    )

    public static let testCall = ToolCall(
        toolCallId: "sample-test",
        title: "swift test --filter LoginViewModelTests",
        kind: .execute,
        status: .completed,
        rawInput: ["command": "swift test --filter LoginViewModelTests"],
        terminalOutput: """
        Building for debugging...
        Build complete! (4.12s)
        Test Suite 'LoginViewModelTests' started.
        Test Case 'testEmptyPasswordIsInvalid' passed (0.002 seconds).
        Test Case 'testValidCredentials' passed (0.001 seconds).
        Executed 2 tests, with 0 failures in 0.003 seconds
        """,
        terminalExitCode: 0
    )

    public static let reply = """
    Fixed. The form only checked the email, so an empty password slipped through.

    `isFormValid` now also requires a password that is not just spaces:

    ```swift
    var isFormValid: Bool {
        !email.isEmpty && !password.trimmingCharacters(in: .whitespaces).isEmpty
    }
    ```

    I added **`testEmptyPasswordIsInvalid`** to `LoginViewModelTests`, and both tests pass.
    """

    public static let plan: [PlanEntry] = [
        PlanEntry(content: "Find where the login form is validated", priority: .high, status: .completed),
        PlanEntry(content: "Require a non-empty password", priority: .high, status: .completed),
        PlanEntry(content: "Add a test for the empty password", priority: .medium, status: .completed),
        PlanEntry(content: "Run the login tests", priority: .low, status: .inProgress),
    ]

    public static let permissionOptions: [PermissionOption] = [
        PermissionOption(optionId: "allow-once", name: "Allow", kind: .allowOnce),
        PermissionOption(optionId: "allow-always", name: "Always Allow", kind: .allowAlways),
        PermissionOption(optionId: "reject", name: "Reject", kind: .rejectOnce),
    ]

    public static let modes = SessionModeState(
        currentModeId: "default",
        availableModes: [
            SessionMode(id: "default", name: "Default", description: "Asks before editing files"),
            SessionMode(id: "acceptEdits", name: "Accept Edits", description: "Edits files without asking"),
            SessionMode(id: "plan", name: "Plan", description: "Plans without changing anything"),
        ]
    )

    public static let configOptions: [SessionConfigOption] = [
        SessionConfigOption(
            id: "mode", name: "Mode", category: .mode, type: .select, currentValue: "default",
            options: .flat(modes.availableModes.map { ConfigOptionValue(value: $0.id, name: $0.name, description: $0.description) })
        ),
        SessionConfigOption(
            id: "model", name: "Model", category: .model, type: .select, currentValue: "sonnet",
            options: .flat([
                ConfigOptionValue(value: "sonnet", name: "Sonnet", description: "Fast and capable"),
                ConfigOptionValue(value: "opus", name: "Opus", description: "Most capable"),
            ])
        ),
        SessionConfigOption(
            id: "effort", name: "Effort", category: .thoughtLevel, type: .select, currentValue: "medium",
            options: .flat([
                ConfigOptionValue(value: "low", name: "Low"),
                ConfigOptionValue(value: "medium", name: "Medium"),
                ConfigOptionValue(value: "high", name: "High"),
            ])
        ),
    ]

    /// A finished turn: prompt, thought, a read, a search, an edit with a diff, a test run with
    /// output, a Markdown reply with a code block, and a plan.
    public static var finishedConversation: ChatTranscript {
        var transcript = startedConversation
        transcript.apply(.toolCall(editCall))
        transcript.apply(.toolCall(testCall))
        transcript.apply(.agentMessageChunk(ContentChunk(content: .text(reply), messageId: "sample-reply")))
        transcript.apply(.plan(plan))
        transcript.apply(.sessionInfo(SessionInfoUpdate(title: "Reject empty passwords at login")))
        transcript.apply(.usage(UsageUpdate(used: 38_400, size: 200_000)))
        transcript.endTurn(.endTurn)
        return transcript
    }

    /// A turn in progress: the reply is half written and the test run is still going.
    public static var streamingConversation: ChatTranscript {
        var transcript = startedConversation
        transcript.apply(.toolCall(editCall))
        var running = testCall
        running.status = .inProgress
        running.terminalOutput = "Building for debugging...\n"
        running.terminalExitCode = nil
        transcript.apply(.toolCall(running))
        transcript.apply(.agentMessageChunk(ContentChunk(content: .text("Fixed. The form only checked the email, so an empty pass"), messageId: "sample-reply")))
        var plan = plan
        plan[2].status = .inProgress
        plan[3].status = .pending
        transcript.apply(.plan(plan))
        return transcript
    }

    /// The edit, proposed and waiting for the user's answer.
    public static var pendingEditConversation: ChatTranscript {
        var transcript = startedConversation
        var pending = editCall
        pending.status = .pending
        transcript.apply(.toolCall(pending))
        return transcript
    }

    /// The permission request that goes with `pendingEditConversation`.
    public static var editPermissionRequest: ChatPermissionRequest {
        var pending = editCall
        pending.status = .pending
        return ChatPermissionRequest(
            id: .int(0),
            options: permissionOptions,
            toolCall: pending,
            requestedToolCall: ToolCallUpdate(toolCallId: editCall.toolCallId, title: editCall.title)
        )
    }

    private static var startedConversation: ChatTranscript {
        var transcript = ChatTranscript()
        transcript.apply(SessionSetup(modes: modes, configOptions: configOptions))
        transcript.apply(.availableCommands([
            AvailableCommand(name: "compact", description: "Summarize the conversation to free up context"),
            AvailableCommand(name: "review", description: "Review the current changes", inputHint: "branch or path"),
        ]))
        transcript.appendUserPrompt([.text(userPrompt)])
        transcript.apply(.agentThoughtChunk(ContentChunk(content: .text(thought), messageId: "sample-thought")))
        transcript.apply(.toolCall(readCall))
        transcript.apply(.toolCall(searchCall))
        return transcript
    }
}
