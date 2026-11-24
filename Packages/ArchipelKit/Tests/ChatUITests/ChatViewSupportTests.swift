import ACPKit
@testable import ChatUI
import Foundation
import Testing

@Suite
struct LineDiffTests {
    private func kinds(_ lines: [DiffLine]) -> String {
        lines.map { line in
            switch line.kind {
            case .context: " "
            case .added: "+"
            case .removed: "-"
            case .gap: "~"
            }
        }.joined()
    }

    @Test func changedLineReadsAsRemovalThenAddition() {
        let lines = LineDiff.lines(old: "a\nb\nc\n", new: "a\nB\nc\n")
        #expect(kinds(lines) == " -+ ")
        #expect(lines.map(\.text) == ["a", "b", "B", "c"])
    }

    @Test func newFileIsAllAdditions() {
        let lines = LineDiff.lines(old: nil, new: "one\ntwo\n")
        #expect(kinds(lines) == "++")
        #expect(LineDiff.stats(old: nil, new: "one\ntwo\n") == LineDiff.Stats(added: 2, removed: 0))
    }

    @Test func trailingNewlineIsNotALine() {
        #expect(LineDiff.splitLines("a\nb\n").count == 2)
        #expect(LineDiff.splitLines("a\nb").count == 2)
        #expect(LineDiff.splitLines("").isEmpty)
        #expect(LineDiff.lines(old: "a\n", new: "a").isEmpty)
    }

    @Test func windowsLineEndingsSplit() {
        #expect(LineDiff.splitLines("a\r\nb\r\n").map(String.init) == ["a", "b"])
    }

    @Test func contextIsTrimmedAndHunksAreSeparated() {
        let old = (1...30).map { "line \($0)" }
        var new = old
        new[2] = "changed 3"
        new[25] = "changed 26"
        let lines = LineDiff.lines(old: old.joined(separator: "\n"), new: new.joined(separator: "\n"), context: 2)
        // Two lines around each change, one marker between the two hunks, none at either end.
        #expect(kinds(lines) == "  -+  ~  -+  ")
        #expect(lines.first?.text == "line 1")
        #expect(lines.last?.text == "line 28")
        #expect(Set(lines.map(\.id)).count == lines.count)
    }

    @Test func statsCountChangedLines() {
        #expect(LineDiff.stats(old: "a\nb\nc\n", new: "a\nB\nc\nd\n") == LineDiff.Stats(added: 2, removed: 1))
        #expect(LineDiff.stats(old: "same\n", new: "same\n") == LineDiff.Stats(added: 0, removed: 0))
    }

    @Test func hugeTextsSkipTheDiff() {
        let old = (0...LineDiff.maximumLines).map { "old \($0)" }.joined(separator: "\n")
        let stats = LineDiff.stats(old: old, new: "new\n")
        #expect(stats == LineDiff.Stats(added: 1, removed: LineDiff.maximumLines + 1))
    }

    @Test func outputTailKeepsTheEnd() {
        let text = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let whole = OutputTail.tail(of: text, maximumLines: 20)
        #expect(whole.lineCount == 10)
        #expect(whole.hiddenLines == 0)
        let tail = OutputTail.tail(of: text, maximumLines: 3)
        #expect(tail.text == "line 8\nline 9\nline 10")
        #expect(tail.hiddenLines == 7)
    }
}

@Suite
struct PermissionChoicesTests {
    private func option(_ id: String, _ name: String, _ kind: PermissionOptionKind) -> PermissionOption {
        PermissionOption(optionId: id, name: name, kind: kind)
    }

    @Test func claudeOptionsBecomeThreeButtons() {
        let choices = PermissionChoices(options: [
            option("allow-once", "Allow", .allowOnce),
            option("allow-with-updates", "Always Allow", .allowAlways),
            option("reject", "Reject", .rejectOnce),
        ])
        #expect(choices.primary?.optionId == "allow-once")
        #expect(choices.primary?.accessibilityIdentifier == "chat.permission.allow")
        #expect(choices.secondary.map(\.optionId) == ["allow-with-updates"])
        #expect(choices.secondary.first?.accessibilityIdentifier == "chat.permission.allowAlways")
        #expect(choices.reject?.optionId == "reject")
        #expect(choices.reject?.accessibilityIdentifier == "chat.permission.reject")
        #expect(choices.overflow.isEmpty)
        #expect(choices.compactOverflow.isEmpty)
    }

    @Test func layoutFollowsKindsNotIdsOrOrder() {
        let choices = PermissionChoices(options: [
            option("reject", "No", .rejectOnce),
            option("always", "Always", .allowAlways),
            option("once", "Once", .allowOnce),
        ])
        #expect(choices.primary?.optionId == "once")
        #expect(choices.secondary.map(\.optionId) == ["always"])
        #expect(choices.reject?.optionId == "reject")
    }

    @Test func wordyNamesKeepTheirWordsAndGetShortStandIns() {
        let choices = PermissionChoices(options: [
            option("allow_once", "Yes, proceed with the command as shown", .allowOnce),
            option("allow_for_session", "Yes, and don't ask again for these files", .allowAlways),
            option("cancel", "No, and tell Codex what to do differently", .rejectOnce),
        ])
        // With room, a button says what the agent said.
        #expect(choices.primary?.name == "Yes, proceed with the command as shown")
        #expect(choices.secondary.first?.name == "Yes, and don't ask again for these files")
        // Without, the default and the reject button fall back to short titles, and the wordy
        // always-allow moves into the menu rather than being cut off.
        #expect(choices.primary?.compactTitle == "Allow")
        #expect(choices.reject?.compactTitle == "Don't Allow")
        #expect(choices.compactSecondary.isEmpty)
        #expect(choices.compactOverflow.map(\.optionId) == ["allow_for_session"])
    }

    @Test func returnNeverGrantsSomethingLasting() {
        let choices = PermissionChoices(options: [
            option("always", "Always Allow", .allowAlways),
            option("reject", "Reject", .rejectOnce),
        ])
        #expect(choices.primary == nil)
        #expect(choices.secondary.map(\.optionId) == ["always"])
    }

    @Test func extraAndUnknownOptionsGoToTheMenu() {
        let choices = PermissionChoices(options: [
            option("a", "Allow", .allowOnce),
            option("b", "Always for This File", .allowAlways),
            option("c", "Always for This Folder", .allowAlways),
            option("d", "Reject", .rejectOnce),
            option("e", "Never", .rejectAlways),
            option("f", "Something Else", .unknown("mystery")),
        ])
        #expect(choices.secondary.map(\.optionId) == ["b"])
        #expect(choices.reject?.optionId == "d")
        #expect(choices.overflow.map(\.optionId) == ["c", "e", "f"])
        #expect(!choices.isEmpty)
    }

    @Test func rejectAlwaysStandsInWhenThereIsNoRejectOnce() {
        let choices = PermissionChoices(options: [option("never", "Never", .rejectAlways)])
        #expect(choices.reject?.optionId == "never")
        #expect(PermissionChoices(options: []).isEmpty)
    }
}

@Suite
struct ComposerKeysTests {
    private func action(_ command: ComposerCommand, _ configure: (inout ComposerKeyContext) -> Void = { _ in }) -> ComposerAction {
        var context = ComposerKeyContext()
        configure(&context)
        return ComposerKeys.action(for: command, in: context)
    }

    @Test func returnSendsOnlyWhenItCan() {
        #expect(action(.newline(modified: false)) { $0.canSend = true; $0.isDraftEmpty = false } == .send)
        // A turn is running or the draft is blank: no stray line break either.
        #expect(action(.newline(modified: false)) { $0.isDraftEmpty = false } == .swallow)
    }

    @Test func modifiedReturnAlwaysInsertsALineBreak() {
        #expect(action(.newline(modified: true)) { $0.canSend = true } == .insertNewline)
        #expect(action(.newline(modified: true)) { $0.isCompletionVisible = true } == .insertNewline)
        #expect(action(.newline(modified: true)) { $0.canAllowPermission = true } == .insertNewline)
    }

    @Test func inputMethodKeepsEveryKey() {
        for command in [ComposerCommand.newline(modified: false), .newline(modified: true), .escape, .tab, .up, .down] {
            let result = action(command) {
                $0.hasMarkedText = true
                $0.canSend = true
                $0.isCompletionVisible = true
                $0.canAllowPermission = true
                $0.canRejectPermission = true
                $0.isTurnRunning = true
            }
            #expect(result == .passThrough)
        }
    }

    @Test func completionListTakesTheNavigationKeys() {
        let visible: (inout ComposerKeyContext) -> Void = { $0.isCompletionVisible = true; $0.canSend = true; $0.isDraftEmpty = false }
        #expect(action(.up, visible) == .moveCompletion(-1))
        #expect(action(.down, visible) == .moveCompletion(1))
        #expect(action(.newline(modified: false), visible) == .acceptCompletion)
        #expect(action(.tab, visible) == .acceptCompletion)
        #expect(action(.escape, visible) == .dismissCompletion)
        // Without the list the arrows move the cursor and Tab is a tab.
        #expect(action(.up) == .passThrough)
        #expect(action(.down) == .passThrough)
        #expect(action(.tab) == .passThrough)
    }

    @Test func returnAnswersAPermissionOnlyWithNothingTyped() {
        #expect(action(.newline(modified: false)) { $0.canAllowPermission = true } == .allowPermission)
        #expect(action(.newline(modified: false)) { $0.canAllowPermission = true; $0.isDraftEmpty = false } == .swallow)
    }

    @Test func escapeGoesToThePermissionCardBeforeTheTurn() {
        #expect(action(.escape) { $0.canRejectPermission = true; $0.isTurnRunning = true } == .rejectPermission)
        #expect(action(.escape) { $0.isTurnRunning = true } == .cancelTurn)
        #expect(action(.escape) == .swallow)
    }
}

@Suite
struct ComposerHabitsTests {
    private func action(_ command: ComposerCommand, _ edit: (inout ComposerKeyContext) -> Void) -> ComposerAction {
        var context = ComposerKeyContext()
        edit(&context)
        return ComposerKeys.action(for: command, in: context)
    }

    @Test func upTakesBackTheQueuedPromptBeforeAnythingSent() {
        #expect(action(.up) { $0.hasQueuedPrompts = true; $0.canRecallOlder = true } == .editQueuedPrompt)
        #expect(action(.up) { $0.hasQueuedPrompts = true; $0.isDraftEmpty = false } == .passThrough)
        #expect(action(.up) { $0.canRecallOlder = true } == .recallPrompt(older: true))
        #expect(action(.down) { $0.canRecallNewer = true } == .recallPrompt(older: false))
    }

    @Test func theArrowsMoveTheCursorInTheUsersOwnText() {
        #expect(action(.up) { $0.isDraftEmpty = false } == .passThrough)
        #expect(action(.down) { $0.isDraftEmpty = false } == .passThrough)
    }

    @Test func shiftTabCyclesTheModeWhenThereIsOne() {
        #expect(action(.backtab) { $0.canCycleMode = true } == .cycleMode)
        #expect(action(.backtab) { _ in } == .passThrough)
        #expect(action(.backtab) { $0.canCycleMode = true; $0.hasMarkedText = true } == .passThrough)
    }

    @Test func recallWalksBackThroughThePromptsAndOutAgain() {
        var recall = PromptRecall(history: ["one", "two", "three"])
        #expect(recall.move(older: false, draft: "") == nil)
        #expect(recall.move(older: true, draft: "") == "three")
        #expect(recall.move(older: true, draft: "three") == "two")
        #expect(recall.move(older: true, draft: "two") == "one")
        #expect(!recall.canRecallOlder(draft: "one"))
        #expect(recall.move(older: false, draft: "one") == "two")
        #expect(recall.move(older: false, draft: "two") == "three")
        #expect(recall.move(older: false, draft: "three") == "")
        #expect(!recall.canRecallNewer(draft: ""))
    }

    @Test func editingARecalledPromptMakesItTheUsersDraft() {
        var recall = PromptRecall(history: ["one", "two"])
        #expect(recall.move(older: true, draft: "") == "two")
        #expect(!recall.canRecallOlder(draft: "two, changed"))
        #expect(!recall.canRecallNewer(draft: "two, changed"))
        #expect(recall.move(older: true, draft: "two, changed") == nil)
    }

    @Test func historyIsTheSentPromptsWithoutBackToBackRepeats() {
        let items: [ChatItem] = [
            .userMessage(ChatMessage(id: "1", text: "fix it")),
            .agentMessage(ChatMessage(id: "2", text: "done")),
            .userMessage(ChatMessage(id: "3", text: "fix it\n")),
            .userMessage(ChatMessage(id: "4", text: "")),
            .userMessage(ChatMessage(id: "5", text: "thanks")),
        ]
        #expect(PromptRecall.history(of: items) == ["fix it", "thanks"])
    }

    @Test func theNextModeWrapsAround() {
        func mode(current: String?) -> ChatControl {
            ChatControl(
                id: "mode", name: "Mode", category: .mode,
                value: .select(current: current, groups: [.init(name: nil, choices: ["ask", "plan", "auto"].map { ConfigOptionValue(value: $0, name: $0) })])
            )
        }
        #expect(mode(current: "ask").nextChoice?.value == "plan")
        #expect(mode(current: "auto").nextChoice?.value == "ask")
        #expect(mode(current: nil).nextChoice?.value == "ask")
        #expect(ChatControl(id: "t", name: "T", category: .mode, value: .toggle(true)).nextChoice == nil)
    }
}

@Suite
struct SlashCommandsTests {
    private let commands = [
        AvailableCommand(name: "compact", description: "Summarize the conversation"),
        AvailableCommand(name: "review", description: "Review the changes"),
        AvailableCommand(name: "security-review", description: "Look for vulnerabilities"),
        AvailableCommand(name: "/init", description: "Set up the project"),
    ]

    @Test func queryNeedsALeadingSlashAndOneWord() {
        #expect(SlashCommands.query(in: "/") == "")
        #expect(SlashCommands.query(in: "/rev") == "rev")
        #expect(SlashCommands.query(in: "") == nil)
        #expect(SlashCommands.query(in: "rev") == nil)
        #expect(SlashCommands.query(in: " /rev") == nil)
        #expect(SlashCommands.query(in: "/review ") == nil)
        #expect(SlashCommands.query(in: "/review\nmore") == nil)
        #expect(SlashCommands.query(in: "a path like /usr/bin") == nil)
    }

    @Test func emptyQueryShowsEverythingInTheAgentsOrder() {
        #expect(SlashCommands.matches(commands, query: "").map(\.name) == ["compact", "review", "security-review", "/init"])
    }

    @Test func prefixMatchesComeBeforeOtherMatches() {
        #expect(SlashCommands.matches(commands, query: "re").map(\.name) == ["review", "security-review"])
        #expect(SlashCommands.matches(commands, query: "REV").map(\.name) == ["review", "security-review"])
        #expect(SlashCommands.matches(commands, query: "sec").map(\.name) == ["security-review"])
        #expect(SlashCommands.matches(commands, query: "zzz").isEmpty)
    }

    @Test func insertionIsTheCommandReadyForArguments() {
        #expect(SlashCommands.insertion(for: commands[1]) == "/review ")
        // A name sent with its slash does not get a second one.
        #expect(SlashCommands.insertion(for: commands[3]) == "/init ")
        #expect(SlashCommands.matches(commands, query: "in").first?.name == "/init")
        // The inserted text is no longer a command being typed, so the list closes.
        #expect(SlashCommands.query(in: SlashCommands.insertion(for: commands[1])) == nil)
    }
}

@Suite
struct ChatRowTests {
    private func call(_ id: String, _ status: ToolCallStatus = .completed) -> ChatItem {
        .toolCall(ToolCall(toolCallId: id, title: "Read \(id)", kind: .read, status: status))
    }

    private func message(_ id: String, _ text: String = "text") -> ChatMessage {
        ChatMessage(id: id, text: text)
    }

    @Test func consecutiveToolCallsShareARow() {
        let items: [ChatItem] = [
            .userMessage(message("u")), call("a"), call("b"), call("c"), .agentMessage(message("m")), call("d"),
        ]
        let rows = ChatRow.rows(for: items, isTurnRunning: false)
        #expect(rows.map(\.id) == ["u", "tool:a", "m", "tool:d"])
        guard case let .tools(_, calls) = rows[1] else {
            Issue.record("expected a tool group")
            return
        }
        #expect(calls.map(\.toolCallId) == ["a", "b", "c"])
    }

    @Test func aGroupKeepsItsIdAsItGrows() {
        let before = ChatRow.rows(for: [call("a")], isTurnRunning: true)
        let after = ChatRow.rows(for: [call("a"), call("b")], isTurnRunning: true)
        #expect(before.map(\.id) == after.map(\.id))
    }

    @Test func onlyTheLastItemStreamsAndOnlyWhileTheTurnRuns() {
        let items: [ChatItem] = [.userMessage(message("u")), .agentThought(message("t")), .agentMessage(message("m"))]
        #expect(ChatRow.rows(for: items, isTurnRunning: true) == [
            .user(message("u")), .thought(message("t"), isStreaming: false), .agent(message("m"), isStreaming: true, endsTurn: false),
        ])
        #expect(ChatRow.rows(for: items, isTurnRunning: false).last == .agent(message("m"), isStreaming: false, endsTurn: true))
    }

    @Test func theReplyBeforeAPromptEndsItsTurn() {
        let items: [ChatItem] = [
            .userMessage(message("u1")), .agentMessage(message("m1")), call("a"), .agentMessage(message("m2")),
            .userMessage(message("u2")),
        ]
        let rows = ChatRow.rows(for: items, isTurnRunning: true)
        #expect(rows[1] == .agent(message("m1"), isStreaming: false, endsTurn: false))
        #expect(rows[3] == .agent(message("m2"), isStreaming: false, endsTurn: true))
    }

    @Test func emptyAgentMessagesAreLeftOut() {
        let rows = ChatRow.rows(for: [.userMessage(message("u")), .agentMessage(message("m", ""))], isTurnRunning: false)
        #expect(rows.map(\.id) == ["u"])
    }

    @Test func workingShowsOnlyWhenNothingElseDoes() {
        func shows(_ items: [ChatItem], running: Bool = true, permission: Bool = false) -> Bool {
            ChatRow.showsWorking(items: items, isTurnRunning: running, isAwaitingPermission: permission)
        }
        #expect(shows([.userMessage(message("u"))]))
        #expect(shows([.userMessage(message("u")), call("a", .completed)]))
        #expect(!shows([.userMessage(message("u")), call("a", .inProgress)]))
        #expect(!shows([.userMessage(message("u")), .agentMessage(message("m"))]))
        #expect(!shows([.userMessage(message("u")), .agentThought(message("t"))]))
        #expect(!shows([.userMessage(message("u"))], running: false))
        #expect(!shows([.userMessage(message("u")), call("a", .completed)], permission: true))
    }

    @Test func spacingGroupsATurnAndSeparatesPrompts() {
        let user = ChatRow.user(message("u"))
        let thought = ChatRow.thought(message("t"), isStreaming: false)
        let tools = ChatRow.tools(id: "tool:a", calls: [])
        let reply = ChatRow.agent(message("m"), isStreaming: false, endsTurn: true)
        #expect(user.spacing(after: nil) == 0)
        #expect(tools.spacing(after: thought) == 0)
        #expect(thought.spacing(after: user) > tools.spacing(after: thought))
        #expect(user.spacing(after: tools) > reply.spacing(after: tools))
        // The reply that ended the turn already leaves a line free under itself.
        #expect(user.spacing(after: reply) < user.spacing(after: tools))
    }
}

@Suite
struct ScrollFollowingTests {
    private func metrics(offset: CGFloat, content: CGFloat, viewport: CGFloat = 500) -> ScrollMetrics {
        ScrollMetrics(offset: offset, contentHeight: content, viewportHeight: viewport)
    }

    @Test func growthAloneNeverStopsFollowing() {
        let old = metrics(offset: 500, content: 1000)
        let new = metrics(offset: 500, content: 1400)
        #expect(new.distanceFromBottom == 400)
        #expect(ScrollFollowing.isFollowing(was: true, old: old, new: new))
        #expect(!ScrollFollowing.isFollowing(was: false, old: old, new: new))
    }

    @Test func scrollingUpStopsFollowing() {
        let old = metrics(offset: 500, content: 1000)
        let new = metrics(offset: 300, content: 1000)
        #expect(!ScrollFollowing.isFollowing(was: true, old: old, new: new))
    }

    @Test func reachingTheBottomStartsFollowingAgain() {
        let old = metrics(offset: 300, content: 1000)
        let new = metrics(offset: 470, content: 1000)
        #expect(ScrollFollowing.isFollowing(was: false, old: old, new: new))
    }

    @Test func aShrinkingPaneKeepsFollowing() {
        // A permission card opens and takes room from below; the offset stays where it was.
        let old = metrics(offset: 500, content: 1000, viewport: 500)
        let new = metrics(offset: 500, content: 1000, viewport: 300)
        #expect(ScrollFollowing.isFollowing(was: true, old: old, new: new))
    }

    @Test func collapsingContentIsNotTheReaderLeaving() {
        // A tool call closes, the content gets shorter and the offset is pulled up with it.
        let old = metrics(offset: 900, content: 2000)
        let new = metrics(offset: 700, content: 1600)
        #expect(ScrollFollowing.isFollowing(was: true, old: old, new: new))
    }
}

@Suite
struct ToolCallPresentationTests {
    @Test func everyKindHasASymbolAndAPhrase() {
        for kind in ToolKind.allCases {
            #expect(!kind.symbolName.isEmpty)
            #expect(kind.permissionPhrase.hasPrefix("wants") || kind.permissionPhrase.hasPrefix("has"))
        }
    }

    @Test func accessibilityLabelNamesTheCallAndItsOutcome() {
        let call = ToolCall(toolCallId: "1", title: "Read README.md", kind: .read, status: .completed)
        #expect(call.accessibilityLabel() == "Read README.md, completed")
        var running = call
        running.status = .inProgress
        #expect(running.accessibilityLabel() == "Read README.md, running")
    }

    @Test func titleIsOneLineWithAFallback() {
        #expect(ToolCall(toolCallId: "1", title: "echo one\necho two", kind: .execute).displayTitle() == "echo one")
        #expect(ToolCall(toolCallId: "1", title: "  ", kind: .execute).displayTitle() == "Run Command")
    }

    @Test func commandComesFromEitherShapeOfRawInput() {
        let claude = ToolCall(toolCallId: "1", title: "swift test", kind: .execute, rawInput: ["command": "swift test"])
        #expect(claude.command == "swift test")
        #expect(!claude.commandDiffersFromTitle)
        let codex = ToolCall(toolCallId: "2", title: "Run command", kind: .execute, rawInput: ["command": ["bash", "-lc", "swift build"]])
        #expect(codex.command == "swift build")
        #expect(codex.commandDiffersFromTitle)
        #expect(codex.permissionSummary() == "swift build")
        let argv = ToolCall(toolCallId: "3", title: "ls", kind: .execute, rawInput: ["command": ["ls", "-la"]])
        #expect(argv.command == "ls -la")
        #expect(ToolCall(toolCallId: "4", title: "x", kind: .execute).command == nil)
    }

    @Test func editRowsCountLinesAndNameTheFile() throws {
        let titled = ChatPreviewSamples.editCall
        let edit = try #require(titled.diffs.first)
        #expect(LineDiff.analysis(old: edit.oldText, new: edit.newText).stats == LineDiff.Stats(added: 1, removed: 1))
        #expect(titled.diffFileNameMissingFromTitle == nil)
        let untitled = ToolCall(
            toolCallId: "1", title: "Edit file", kind: .edit,
            content: [.diff(path: "/tmp/Package.swift", oldText: nil, newText: "a\nb\n")]
        )
        #expect(untitled.diffFileNameMissingFromTitle == "Package.swift")
        #expect(LineDiff.analysis(old: nil, new: "a\nb\n").stats == LineDiff.Stats(added: 2, removed: 0))
        #expect(ChatPreviewSamples.readCall.diffs.isEmpty)
    }

    @Test func detailsExistOnlyWhenThereIsSomethingToShow() {
        #expect(!ToolCall(toolCallId: "1", title: "Think", kind: .think).hasDetails)
        #expect(ChatPreviewSamples.readCall.hasDetails)
        #expect(ChatPreviewSamples.searchCall.hasDetails)
        #expect(ChatPreviewSamples.testCall.hasDetails)
        #expect(ToolCall(toolCallId: "1", title: "x", kind: .execute, terminalExitCode: 2).hasDetails)
        #expect(!ToolCall(toolCallId: "1", title: "x", kind: .other, content: [.content(.text("  \n"))]).hasDetails)
    }

    @Test func permissionSummaryPrefersWhatIsBeingTouched() {
        #expect(ChatPreviewSamples.editCall.permissionSummary() == "/Users/me/Projects/Acme/Sources/Login/LoginViewModel.swift")
        #expect(ToolCall(toolCallId: "1", title: "Plan", kind: .switchMode).permissionSummary() == nil)
        #expect(ToolCall(toolCallId: "1", title: "Fetch example.com", kind: .fetch).permissionSummary() == "Fetch example.com")
    }

    @Test func locationsNameTheFileAndLine() {
        #expect(ToolCallLocation(path: "/a/b/File.swift", line: 12).displayName == "File.swift:12")
        #expect(ToolCallLocation(path: "/a/b/File.swift").displayName == "File.swift")
    }

    @Test func permissionSummaryAndTitlesAreRelativeToTheWorkingDirectory() {
        let edit = ToolCall(toolCallId: "1", title: "Edit /work/repo/a.txt", kind: .edit, locations: [ToolCallLocation(path: "/work/repo/a.txt")])
        #expect(edit.permissionSummary(relativeTo: "/work/repo") == "a.txt")
        #expect(edit.displayTitle(relativeTo: "/work/repo") == "Edit a.txt")
        #expect(edit.displayTitle() == "Edit /work/repo/a.txt")
        let run = ToolCall(toolCallId: "2", title: "cat /work/repo/a.txt", kind: .execute)
        #expect(run.displayTitle(relativeTo: "/work/repo") == "cat /work/repo/a.txt")
        #expect(ToolCallLocation(path: "/work/repo/src/B.swift", line: 3).displayLabel(relativeTo: "/work/repo") == "src/B.swift:3")
        #expect(ToolCallLocation(path: "/work/repo/src/B.swift").displayLabel(relativeTo: nil) == "/work/repo/src/B.swift")
    }
}

@Suite
struct DisplayPathTests {
    private let home = "/Users/me"

    private func shown(_ path: String, in directory: String) -> String {
        displayPath(path, relativeTo: directory, home: home)
    }

    @Test func insideTheDirectoryIsRelative() {
        #expect(shown("/work/repo/hello.txt", in: "/work/repo") == "hello.txt")
        #expect(shown("/work/repo/a/b.txt", in: "/work/repo") == "a/b.txt")
    }

    @Test func trailingSlashOnTheDirectoryIsIgnored() {
        #expect(shown("/work/repo/hello.txt", in: "/work/repo/") == "hello.txt")
    }

    @Test func theDirectoryItselfIsDot() {
        #expect(shown("/work/repo", in: "/work/repo") == ".")
        #expect(shown("/work/repo/", in: "/work/repo") == ".")
    }

    @Test func aSiblingWithTheSamePrefixIsOutside() {
        #expect(shown("/work/repo2/a.txt", in: "/work/repo") == "/work/repo2/a.txt")
    }

    @Test func outsideTheDirectoryUsesTildeForHome() {
        #expect(shown("/Users/me/Notes/a.md", in: "/work/repo") == "~/Notes/a.md")
        #expect(shown("/Users/me", in: "/work/repo") == "~")
        #expect(shown("/Users/mel/a.md", in: "/work/repo") == "/Users/mel/a.md")
        #expect(shown("/etc/hosts", in: "/work/repo") == "/etc/hosts")
    }

    @Test func theDirectoryWinsOverHome() {
        #expect(shown("/Users/me/repo/a.txt", in: "/Users/me/repo") == "a.txt")
    }

    @Test func systemLinkSpellingsAreTheSamePlace() {
        #expect(shown("/private/tmp/x/repo/hello.txt", in: "/tmp/x/repo") == "hello.txt")
        #expect(shown("/tmp/x/repo/hello.txt", in: "/private/tmp/x/repo") == "hello.txt")
        #expect(shown("/private/var/folders/a/b.txt", in: "/var/folders") == "a/b.txt")
        #expect(shown("/var/folders/a/b.txt", in: "/private/var/folders/") == "a/b.txt")
    }

    @Test func dotSegmentsAreResolved() {
        #expect(shown("/work/repo/./a/../b.txt", in: "/work/repo") == "b.txt")
        #expect(shown("/work/repo/../other/b.txt", in: "/work/repo") == "/work/repo/../other/b.txt")
    }

    @Test func relativePathsAndAnEmptyDirectoryAreLeftAlone() {
        #expect(shown("src/a.txt", in: "/work/repo") == "src/a.txt")
        #expect(shown("/work/repo/a.txt", in: "") == "/work/repo/a.txt")
        #expect(shown("/work/repo/a.txt", in: "/") == "/work/repo/a.txt")
    }
}

@Suite
struct ChatControlLabelTests {
    private func select(_ name: String, _ category: ConfigOptionCategory?, current: String, name choice: String) -> ChatControl {
        ChatControl(
            id: name, name: name, category: category,
            value: .select(current: current, groups: [.init(name: nil, choices: [ConfigOptionValue(value: current, name: choice)])])
        )
    }

    @Test func modeAndModelShowTheValueAlone() {
        #expect(select("Mode", .mode, current: "m", name: "Manual").barLabel == "Manual")
        #expect(select("Model", .model, current: "d", name: "Default (recommended)").barLabel == "Default (recommended)")
    }

    @Test func otherControlsCarryTheirName() {
        #expect(select("Effort", .thoughtLevel, current: "m", name: "Medium").barLabel == "Effort: Medium")
        #expect(select("Fast Mode", nil, current: "o", name: "Off").barLabel == "Fast Mode: Off")
        #expect(select("Style", .unknown("x"), current: "d", name: "Default").barLabel == "Style: Default")
    }

    @Test func aValueThatNamesTheControlIsNotRepeated() {
        #expect(select("Thinking", .custom, current: "e", name: "Extended thinking").barLabel == "Extended thinking")
    }

    @Test func togglesReadOnOrOff() {
        #expect(ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(true)).barLabel == "Brief: On")
        #expect(ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(false)).barLabel == "Brief: Off")
    }

    @Test func aChoiceThatIsNotListedFallsBackToTheName() {
        let control = ChatControl(id: "x", name: "Effort", category: nil, value: .select(current: "?", groups: []))
        #expect(control.barLabel == "Effort")
    }

    @Test func onlyTheModeAndTheModelArePrimary() {
        #expect(select("Mode", .mode, current: "m", name: "Manual").isPrimary)
        #expect(select("Model", .model, current: "d", name: "Default").isPrimary)
        #expect(!select("Effort", .thoughtLevel, current: "m", name: "Medium").isPrimary)
        #expect(!select("Agent", nil, current: "d", name: "Default").isPrimary)
    }

    @Test func aChoiceBetweenOnAndOffIsASwitch() {
        func control(_ values: [String]) -> ChatControl {
            ChatControl(
                id: "x", name: "Fast mode", category: nil,
                value: .select(current: values.first, groups: [.init(name: nil, choices: values.map { ConfigOptionValue(value: $0, name: $0) })])
            )
        }
        #expect(control(["off", "on"]).switchValues.map { [$0.on, $0.off] } == ["on", "off"])
        #expect(control(["On", "Off"]).switchValues.map { [$0.on, $0.off] } == ["On", "Off"])
        #expect(control(["off", "on", "auto"]).switchValues == nil)
        #expect(control(["low", "high"]).switchValues == nil)
        #expect(ChatControl(id: "t", name: "Brief", category: nil, value: .toggle(true)).switchValues == nil)
    }

    private func effort(_ values: [String], category: ConfigOptionCategory? = .thoughtLevel) -> ChatControl {
        ChatControl(
            id: "effort", name: "Effort", category: category,
            value: .select(current: values.first, groups: [.init(name: nil, choices: values.map { ConfigOptionValue(value: $0, name: $0) })])
        )
    }

    @Test func theEffortIsAScaleOfItsLevels() {
        #expect(effort(["low", "medium", "high", "xhigh"]).levelScale?.levels.map(\.value) == ["low", "medium", "high", "xhigh"])
        #expect(effort(["low", "medium", "high", "xhigh"]).levelScale?.fallback == nil)
    }

    @Test func defaultIsNotAStopOnTheScale() {
        let scale = effort(["default", "low", "medium", "high"]).levelScale
        #expect(scale?.levels.map(\.value) == ["low", "medium", "high"])
        #expect(scale?.fallback?.value == "default")
    }

    @Test func onlyAnEffortWithLevelsToMoveBetweenIsAScale() {
        #expect(effort(["default", "high"]).levelScale == nil)
        #expect(effort(["low", "medium", "high"], category: .mode).levelScale == nil)
        #expect(ChatControl(id: "t", name: "Think", category: .thoughtLevel, value: .toggle(true)).levelScale == nil)
    }

    @Test func aShortDescriptionIsItsOwnSummary() {
        #expect(ChatControl.menuSummary(of: "Reviews code changes") == "Reviews code changes")
        #expect(ChatControl.menuSummary(of: "Requires approval to edit files.") == "Requires approval to edit files")
        #expect(ChatControl.menuSummary(of: nil) == nil)
        #expect(ChatControl.menuSummary(of: "  \n") == nil)
    }

    @Test func aLongDescriptionIsCutToItsFirstSentenceAndOneLine() {
        #expect(ChatControl.menuSummary(of: "The default agent. Executes tools based on configured permissions.") == "The default agent")
        #expect(ChatControl.menuSummary(of: "First line\nSecond line") == "First line")
        let long = "Use this agent when you need to review code for adherence to project guidelines, style guides, and best practices."
        #expect(ChatControl.menuSummary(of: long) == "Use this agent when you need to review code for adherence to…")
        #expect(ChatControl.menuSummary(of: String(repeating: "a", count: 80)) == String(repeating: "a", count: 60) + "…")
    }

    private func models(_ values: [String], current: String?, category: ConfigOptionCategory? = .model) -> ChatControl {
        ChatControl(
            id: "model", name: "Model", category: category,
            value: .select(current: current, groups: [.init(name: nil, choices: values.map { ConfigOptionValue(value: $0, name: $0) })])
        )
    }

    private let manyModels = ["a/1", "a/2", "a/3", "b/1", "b/2", "b/3", "b/4", "c/1", "c/2", "c/3"]

    @Test func aShortModelListIsShownWhole() {
        #expect(models(["opus", "fable", "sonnet", "haiku"], current: "opus").modelShortlist(recent: []) == nil)
        #expect(models(Array(manyModels.prefix(8)), current: "a/1").modelShortlist(recent: []) == nil)
        #expect(models(manyModels, current: "a/1", category: .mode).modelShortlist(recent: []) == nil)
    }

    @Test func aLongModelListShowsTheCurrentTheRecentAndTheProviderInUse() {
        let shortlist = models(manyModels, current: "b/3").modelShortlist(recent: ["c/2", "gone", "a/1"])
        // The model in use, the two recent ones still offered, then its provider's first two.
        #expect(shortlist?.shown.map(\.value) == ["a/1", "b/1", "b/2", "b/3", "c/2"])
        #expect(shortlist?.others.flatMap(\.choices).map(\.value) == ["a/2", "a/3", "b/4", "c/1", "c/3"])
    }

    @Test func withNothingToGoOnTheAgentsFirstModelsAreShown() {
        let plain = ["m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8", "m9"]
        #expect(models(plain, current: nil).modelShortlist(recent: [])?.shown.map(\.value) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(models(plain, current: "m9").modelShortlist(recent: [])?.shown.map(\.value) == ["m1", "m2", "m3", "m4", "m9"])
    }

    @Test func groupsLeftEmptyAreDropped() {
        let control = ChatControl(
            id: "model", name: "Model", category: .model,
            value: .select(current: "a/1", groups: [
                .init(name: "A", choices: ["a/1", "a/2"].map { ConfigOptionValue(value: $0, name: $0) }),
                .init(name: "B", choices: (1...8).map { ConfigOptionValue(value: "b/\($0)", name: "b/\($0)") }),
            ])
        )
        let shortlist = control.modelShortlist(recent: ["b/1", "b/2", "b/3"])
        #expect(shortlist?.shown.map(\.value) == ["a/1", "a/2", "b/1", "b/2", "b/3"])
        #expect(shortlist?.others.map(\.name) == ["B"])
    }

    @Test func recentModelsKeepTheLatestFirstAndEachOnce() {
        var stored = ""
        for value in ["a", "b", "a", "c"] { stored = RecentModels.adding(value, to: stored) }
        #expect(RecentModels.values(in: stored) == ["c", "a", "b"])
        for index in 0..<20 { stored = RecentModels.adding("m\(index)", to: stored) }
        #expect(RecentModels.values(in: stored).count == RecentModels.capacity)
        #expect(RecentModels.values(in: stored).first == "m19")
    }

    @Test func modesAreKnownByTheWordsAgentsShare() {
        func style(_ value: String, _ name: String) -> ChatControl.ModeStyle {
            ChatControl.modeStyle(for: ConfigOptionValue(value: value, name: name))
        }
        #expect(style("default", "Manual").symbol == "hand.raised")
        #expect(style("acceptEdits", "Accept edits").symbol == "pencil")
        #expect(style("plan", "Plan").symbol == "list.clipboard")
        #expect(style("auto", "Auto").symbol == "sparkles")
        #expect(style("read-only", "Read-only").symbol == "eye")
        #expect(style("workspace-write", "Workspace access").symbol == "pencil")
        #expect(style("agent", "Auto review").symbol == "sparkles")
        #expect(style("build", "Build").symbol == "hammer")
        #expect(style("x", "Something Else") == ChatControl.ModeStyle(symbol: "switch.2"))
    }

    @Test func onlyAModeWithoutLimitsIsMarked() {
        func style(_ value: String, _ name: String) -> ChatControl.ModeStyle {
            ChatControl.modeStyle(for: ConfigOptionValue(value: value, name: name))
        }
        #expect(style("agent-full-access", "Full access").isUnrestricted)
        #expect(style("bypassPermissions", "Bypass permissions").isUnrestricted)
        #expect(!style("auto", "Auto").isUnrestricted)
        #expect(!style("acceptEdits", "Accept edits").isUnrestricted)
    }

    @Test func theDefaultModelIsShownByItsName() {
        func model(_ value: String, _ name: String, _ description: String?) -> ChatControl {
            ChatControl(
                id: "model", name: "Model", category: .model,
                value: .select(current: value, groups: [.init(name: nil, choices: [ConfigOptionValue(value: value, name: name, description: description)])])
            )
        }
        #expect(model("default", "Default (recommended)", "Opus 5.5").barLabel == "Opus 5.5")
        #expect(model("default", "Default", nil).barLabel == "Default")
        #expect(model("default", "Default", "Whatever the provider considers best for this account today").barLabel == "Default")
        #expect(model("opus", "Opus 5.5", "For complex work").barLabel == "Opus 5.5")
    }

    @Test func theGaugeFollowsTheLevel() {
        let scale = effort(["default", "low", "medium", "high"]).levelScale
        func fraction(_ current: String) -> Double? {
            var control = effort(["default", "low", "medium", "high"])
            if case let .select(_, groups) = control.value { control.value = .select(current: current, groups: groups) }
            return scale?.fraction(of: control)
        }
        #expect(fraction("low") == 0)
        #expect(fraction("medium") == 0.5)
        #expect(fraction("high") == 1)
        #expect(fraction("default") == nil)
        #expect(ChatControl.LevelScale.gaugeSymbol(for: 0) == "gauge.with.dots.needle.0percent")
        #expect(ChatControl.LevelScale.gaugeSymbol(for: 1.0 / 3) == "gauge.with.dots.needle.33percent")
        #expect(ChatControl.LevelScale.gaugeSymbol(for: nil) == "gauge.with.dots.needle.50percent")
        #expect(ChatControl.LevelScale.gaugeSymbol(for: 2.0 / 3) == "gauge.with.dots.needle.67percent")
        #expect(ChatControl.LevelScale.gaugeSymbol(for: 1) == "gauge.with.dots.needle.100percent")
    }
}
