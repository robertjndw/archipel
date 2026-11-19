import Foundation
import Testing
import ArchipelCore

struct RuntimeAgentTests {
    let first = ProcessIdentity(pid: 100, startTime: 1)
    let second = ProcessIdentity(pid: 200, startTime: 2)
    /// A `claude -p` that `first` runs through its Bash tool.
    let nested = ProcessIdentity(pid: 300, startTime: 3)
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func claude(_ process: ProcessIdentity) -> ForegroundObservation {
        ForegroundObservation(agent: .claude, process: process, shellInForeground: false)
    }

    private let shellBack = ForegroundObservation(shellInForeground: true)
    /// Something else in the foreground, `vim` say.
    private let otherProgram = ForegroundObservation(shellInForeground: false)

    private func hooked(_ id: String = "a") -> RuntimeAgentState {
        var state = RuntimeAgentState()
        state.observe(claude(first))
        state.hookStarted(agentSessionID: id, source: "startup", sender: first)
        return state
    }

    /// `#expect` cannot take a mutating call.
    private func accepts(_ state: inout RuntimeAgentState, _ id: String, sender: ProcessIdentity? = nil) -> Bool {
        state.hookEvent(agentSessionID: id, sender: sender)
    }

    /// Found by a scan, before any of its hooks (or with the hooks turned on while it ran).
    private func scanned() -> RuntimeAgentState {
        var state = RuntimeAgentState()
        state.observe(claude(first), at: now)
        return state
    }

    // MARK: Scans

    @Test func scanFindsAndLosesTheAgent() {
        var state = RuntimeAgentState()
        state.observe(claude(first))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
        state.observe(shellBack)
        #expect(state.agent == nil)
    }

    @Test func suspendingTheAgentEndsIt() {
        // Ctrl-Z puts the shell back in the foreground while the process still exists.
        var state = hooked()
        state.observe(shellBack)
        #expect(state.agent == nil)
    }

    @Test func anotherProgramInTheForegroundEndsAScannedAgent() {
        var state = RuntimeAgentState()
        state.observe(claude(first))
        state.observe(otherProgram)
        #expect(state.agent == nil)
    }

    @Test func aNewProcessIsANewRun() {
        var state = hooked()
        state.observe(claude(second))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: second))
    }

    @Test func theSameProcessKeepsWhatItsHooksSaid() {
        var state = hooked()
        state.observe(claude(first))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "a"))
    }

    @Test func aHookOnlyAgentWaitsForTheShell() {
        var state = RuntimeAgentState()
        state.hookStarted(agentSessionID: "a", source: "startup")
        #expect(state.agent == RuntimeAgent(kind: .claude, reportsThroughHooks: true, agentSessionID: "a"))
        // An unrecognised wrapper in the foreground doesn't tell whether Claude runs under it.
        state.observe(otherProgram)
        #expect(state.agent != nil)
        state.observe(claude(first))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "a"))

        var waiting = RuntimeAgentState()
        waiting.hookStarted(agentSessionID: "a", source: "startup")
        waiting.observe(shellBack)
        #expect(waiting.agent == nil)
    }

    @Test func anAgentThatEndedIsNotFoundAgainWhileItShutsDown() {
        var state = hooked()
        state.hookEnded(agentSessionID: "a", reason: "prompt_input_exit")
        #expect(state.agent == nil)
        state.observe(claude(first))
        #expect(state.agent == nil)
        state.observe(claude(second))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: second))
    }

    // MARK: Hooks

    @Test func aNestedClaudeIsIgnored() {
        var state = hooked()
        state.hookStarted(agentSessionID: "nested", source: "startup")
        #expect(state.agent?.agentSessionID == "a")
        #expect(accepts(&state, "nested") == false)
        state.hookEnded(agentSessionID: "nested", reason: "other")
        #expect(state.agent?.agentSessionID == "a")
        #expect(accepts(&state, "a"))
    }

    @Test func clearMovesToTheNewConversation() {
        var state = hooked()
        // Only /clear ends a conversation without ending the process.
        state.hookEnded(agentSessionID: "a", reason: "clear")
        #expect(state.agent?.agentSessionID == "a")
        state.hookStarted(agentSessionID: "b", source: "clear")
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "b"))
        #expect(accepts(&state, "a") == false)
        #expect(accepts(&state, "b"))
    }

    @Test func resumeRepinsWithoutAnEnd() {
        var state = hooked()
        state.hookStarted(agentSessionID: "b", source: "resume")
        #expect(state.agent?.agentSessionID == "b")
        #expect(state.agent?.process == first)
    }

    @Test func aScannedAgentAdoptsTheFirstHook() {
        var state = RuntimeAgentState()
        state.observe(claude(first))
        #expect(accepts(&state, "a"))
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "a"))
    }

    @Test func hooksWithoutAnAgentAreIgnored() {
        var state = RuntimeAgentState()
        #expect(accepts(&state, "a") == false)
        state.hookEnded(agentSessionID: "a", reason: "other")
        #expect(state == RuntimeAgentState())
    }

    @Test func endOfAnotherConversationIsIgnored() {
        var state = hooked()
        state.hookEnded(agentSessionID: "z", reason: "logout")
        #expect(state.agent != nil)
        state.hookEnded(agentSessionID: "a", reason: "logout")
        #expect(state.agent == nil)
    }

    // MARK: Telling Claudes apart by their processes

    @Test func aNestedClaudeCannotTakeOverAScannedOne() {
        var state = scanned()
        state.hookStarted(agentSessionID: "nested", source: "startup", sender: nested, at: now)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
        #expect(accepts(&state, "nested", sender: nested) == false)
        state.hookEnded(agentSessionID: "nested", reason: "other", sender: nested, at: now)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
        // Its end must not keep the real one from being found either.
        state.observe(claude(first), at: now + 1)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
    }

    @Test func aNestedClaudeCannotTakeOverAHookedOne() {
        var state = hooked()
        state.hookStarted(agentSessionID: "nested", source: "resume", sender: nested, at: now)
        #expect(state.agent?.agentSessionID == "a")
        #expect(accepts(&state, "a", sender: nested) == false)
    }

    @Test func aStartupWithoutASenderIsNotAdoptedByAScannedAgent() {
        // An older helper sends no sender, and the scanned Claude's own SessionStart would have
        // arrived long ago.
        var state = scanned()
        state.hookStarted(agentSessionID: "nested", source: "startup", at: now)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
        state.hookStarted(agentSessionID: "b", source: "startup", sender: first, at: now)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "b"))
    }

    @Test func theAgentsOwnHooksCountWhateverTheConversation() {
        var state = hooked()
        #expect(accepts(&state, "z", sender: first))
        #expect(state.agent?.agentSessionID == "z")
        state.hookEnded(agentSessionID: "other", reason: "logout", sender: first, at: now)
        #expect(state.agent == nil)
    }

    // MARK: Expiry

    @Test func aReportedEndStopsBlockingAfterTheGrace() {
        var state = scanned()
        _ = accepts(&state, "a")
        state.hookEnded(agentSessionID: "a", reason: "resume", at: now)
        #expect(state.agent == nil)
        state.observe(claude(first), at: now + 1)
        #expect(state.agent == nil)
        state.observe(claude(first), at: now + RuntimeAgentState.endedProcessGrace)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first))
    }

    @Test func aHookFromTheEndedProcessBringsItBackAtOnce() {
        var state = scanned()
        _ = accepts(&state, "a")
        state.hookEnded(agentSessionID: "a", reason: "resume", at: now)
        state.hookStarted(agentSessionID: "b", source: "resume", sender: first, at: now)
        state.attach(first)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "b"))
        state.observe(claude(first), at: now + 1)
        #expect(state.agent?.process == first)
    }

    @Test func aHookOnlyAgentNoScanFindsExpires() {
        // Under tmux the shell never comes back to the foreground, and a Claude killed without
        // SessionEnd would otherwise stay for as long as tmux runs.
        var state = RuntimeAgentState()
        state.hookStarted(agentSessionID: "a", source: "startup", at: now)
        state.observe(otherProgram, at: now + RuntimeAgentState.unattachedLimit - 1)
        #expect(state.agent != nil)
        state.observe(otherProgram, at: now + RuntimeAgentState.unattachedLimit)
        #expect(state.agent == nil)
    }

    @Test func anAttachedAgentDoesNotExpire() {
        var state = RuntimeAgentState()
        state.hookStarted(agentSessionID: "a", source: "startup", at: now)
        state.attach(first)
        state.observe(claude(first), at: now + 100)
        #expect(state.agent == RuntimeAgent(kind: .claude, process: first, reportsThroughHooks: true, agentSessionID: "a"))
    }

    // MARK: Matching

    @Test(arguments: [
        (ProcessLabel.label(name: "2.1.3", arguments: ["claude"]), true),
        (ProcessLabel.label(name: "2.1.3", arguments: ["/Users/me/.local/bin/claude", "--resume"]), true),
        (ProcessLabel.label(name: "node", arguments: ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]), true),
        (ProcessLabel.label(name: "node", arguments: ["node", "/srv/app/server.js"]), false),
        (ProcessLabel.label(name: "codex", arguments: ["codex"]), false),
    ])
    func claudeIsRecognisedByItsLabel(label: String, isClaude: Bool) {
        #expect((AgentProcessMatcher.agent(forLabel: label) == .claude) == isClaude)
    }

    @Test(arguments: ["-zsh", "zsh", "fish", "-fish", "bash", "nu", ProcessLabel.label(name: "fish", arguments: ["/opt/homebrew/bin/fish", "-l"])])
    func shellsAreRecognised(label: String) {
        #expect(AgentProcessMatcher.isShell(label: label))
    }

    @Test(arguments: ["vim", "claude", "-", "zshrc"])
    func otherProgramsAreNotShells(label: String) {
        #expect(!AgentProcessMatcher.isShell(label: label))
    }

    @Test(arguments: [
        ("Claude needs your permission to use Bash", AttentionReason?.some(.permission)),
        ("Claude is waiting for your input", nil),
        ("Claude has a question for you", .question),
    ])
    func terminalNotifications(body: String, reason: AttentionReason?) {
        #expect(ClaudeTerminalNotification.reason(forBody: body) == reason)
    }
}
