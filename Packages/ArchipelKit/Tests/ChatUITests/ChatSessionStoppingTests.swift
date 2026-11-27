import ACPKit
import ArchipelCore
@testable import ChatUI
import Foundation
import Testing

/// Ways out of a chat that hangs: deadlines while starting, cancelling a start or a sign-in, a
/// turn that ignores Stop, and shutting down an agent in the middle of a turn.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ChatSessionStoppingTests {
    /// Short enough to wait out, long enough for an in-memory agent that does answer.
    private static let quickDeadlines = ChatSession.Timing(request: .milliseconds(400), loadSession: .milliseconds(400))
    private static let quickGrace = ChatSession.Timing(cancelGrace: .milliseconds(100))

    private static let authMethods: [JSONValue] = [
        ["id": "browser", "name": "Sign In with Browser", "type": "agent"],
    ]

    // MARK: Deadlines

    @Test func anAgentThatNeverInitializesFailsWithItsStderr() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .silent
        let harness = ChatHarness(script: script, stderr: "waiting for something\n", timing: Self.quickDeadlines)
        await harness.session.start()
        let failure = try #require(harness.session.phase.failure)
        #expect(failure.reason == .couldNotStart)
        #expect(failure.title == "Could Not Start Fake Agent")
        #expect(failure.message == "Fake Agent didn't respond.")
        #expect(failure.details == "waiting for something")
        #expect(harness.events == [.failed(failure)])
        // The agent was stopped: its end of the pipe sees end of input.
        let agent = try harness.agent()
        try await waitUntil("the agent's input closes") { (try? agent.agentText("s-new", "late")) == nil }
        #expect(harness.session.connection == nil)
        #expect(harness.session.client == nil)
    }

    @Test func aSessionThatNeverOpensFailsAndTryAgainStartsOver() async throws {
        var script = ScriptedAgent.Script()
        script.newSession = [.silent]
        let harness = ChatHarness(script: script, timing: Self.quickDeadlines)
        await harness.session.start()
        #expect(harness.session.phase.failure?.message == "Fake Agent didn't respond.")

        harness.editTemplate { $0.newSession = [.result(["sessionId": "s-2"])] }
        await harness.session.retry()
        #expect(harness.session.phase == .ready)
        #expect(harness.session.agentSessionID == "s-2")
        #expect(harness.launchCount == 2)
        await harness.session.shutDown()
    }

    @Test func aRestoreThatTimesOutIsRestoredAgainOnRetry() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(loadSession: true))
        script.load = .silent
        let harness = ChatHarness(script: script, existingSessionID: "s-old", timing: Self.quickDeadlines)
        await harness.session.start()
        #expect(harness.session.phase.failure?.message == "Fake Agent didn't respond.")

        harness.editTemplate { $0.load = .result([:]) }
        await harness.session.retry()
        #expect(harness.session.phase == .ready)
        let agent = try harness.agent()
        #expect(agent.requests(ACPMethod.sessionLoad).first?.params["sessionId"] == "s-old")
        #expect(agent.requests(ACPMethod.sessionNew).isEmpty)
        await harness.session.shutDown()
    }

    // MARK: Cancelling a start

    @Test func cancellingWhileInstallingStopsTheInstall() async throws {
        let sawCancellation = Locked(false)
        let harness = ChatHarness(resolveLaunch: { progress in
            progress(.downloading(fraction: 0.1))
            // Stands in for a download, which ends when its task is cancelled.
            try? await Task.sleep(for: .seconds(30))
            sawCancellation.withLock { $0 = Task.isCancelled }
            throw CancellationError()
        })
        let start = Task { await harness.session.start() }
        try await waitUntil("installing shows") {
            harness.session.phase == .starting(.installing(agentName: "Fake Agent", fraction: 0.1))
        }
        harness.session.cancelStart()
        let failure = try #require(harness.session.phase.failure)
        #expect(failure.reason == .couldNotStart)
        #expect(failure.message == "Starting Fake Agent was canceled.")
        await start.value
        #expect(sawCancellation.withLock { $0 })
        // Nothing the abandoned start does afterwards changes what is shown.
        #expect(harness.session.phase.failure == failure)
        #expect(harness.events == [.failed(failure)])
        #expect(harness.launchCount == 0)
    }

    @Test func cancellingWhileConnectingStopsTheAgent() async throws {
        var script = ScriptedAgent.Script()
        script.newSession = [.silent]
        let harness = ChatHarness(script: script)
        let start = Task { await harness.session.start() }
        try await waitUntil("the agent is asked for a session") {
            harness.launchCount == 1 && (try? harness.agent().requests(ACPMethod.sessionNew).isEmpty) == false
        }
        harness.session.cancelStart()
        await start.value
        #expect(harness.session.phase.failure?.message == "Starting Fake Agent was canceled.")
        let agent = try harness.agent()
        try await waitUntil("the agent's input closes") { (try? agent.agentText("s-new", "late")) == nil }
    }

    @Test func cancellingASignInAsksAgain() async throws {
        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(authMethods: Self.authMethods))
        script.newSession = [.error(JSONRPCError.authenticationRequired, "Authentication required"), .result(["sessionId": "s-new"])]
        script.authenticate = .silent
        let harness = ChatHarness(script: script)
        await harness.session.start()
        let asking = try #require(harness.session.phase.failure)

        let signIn = Task { await harness.session.authenticate(methodId: "browser") }
        try await waitUntil("signing in") { harness.session.phase == .starting(.signingIn) }
        harness.session.cancelStart()
        #expect(harness.session.phase == .failed(asking))

        // The agent is still there, and signing in again works.
        let agent = try harness.agent()
        agent.editScript { $0.authenticate = .result([:]) }
        await harness.session.authenticate(methodId: "browser")
        #expect(harness.session.phase == .ready)
        #expect(harness.launchCount == 1)
        await harness.session.shutDown()
        // The abandoned attempt fails with the connection and changes nothing.
        await signIn.value
        #expect(harness.session.phase.ending != nil)
    }

    // MARK: Stopping a turn

    @Test func aTurnThatIgnoresStopEndsTheChatOnTheSecondPress() async throws {
        let harness = ChatHarness(timing: Self.quickGrace)
        try await harness.start()
        try await harness.send("Loop forever")
        await harness.session.cancel()
        #expect(harness.session.isCancelling)
        #expect(!harness.session.isCancelIgnored)
        // A second press during the grace does nothing.
        await harness.session.cancel()
        #expect(harness.session.phase == .ready)

        try await waitUntil("Stop works again") { harness.session.isCancelIgnored }
        harness.clearEvents()
        await harness.session.cancel()
        let ending = try #require(harness.session.phase.ending)
        #expect(ending.message == "Fake Agent was stopped.")
        #expect(ending.isClean)
        #expect(!harness.session.isTurnRunning)
        #expect(!harness.session.isCancelling)
        #expect(!harness.session.isCancelIgnored)
        #expect(harness.session.transcript.lastStopReason == .cancelled)
        #expect(harness.events == [.agent(.processExited(code: 0))])
        #expect(harness.terminations.withLock { $0 } == 1)
        #expect(harness.session.client == nil)
    }

    @Test func aTurnThatEndsDuringTheGraceLeavesStopAlone() async throws {
        let harness = ChatHarness(timing: Self.quickGrace)
        try await harness.start()
        let promptID = try await harness.send("Work")
        await harness.session.cancel()
        try harness.agent().finishPrompt(promptID, stopReason: "cancelled")
        try await waitUntil("the turn ends") { !harness.session.isTurnRunning }
        // The grace runs out after the turn ended; nothing is armed for the next turn.
        try await harness.send("Next")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!harness.session.isCancelIgnored)
        await harness.session.shutDown()
    }

    // MARK: Shutting down

    @Test func shuttingDownMidTurnCancelsTheTurnFirst() async throws {
        let harness = ChatHarness()
        try await harness.start()
        let agent = try harness.agent()
        try await harness.send("Edit everything")
        await harness.session.shutDown()
        // Sent before shutDown returns, but the fake agent reads it on its own task.
        try await waitUntil("the agent receives the cancel") {
            !agent.notifications(ACPMethod.sessionCancel).isEmpty
        }
        #expect(agent.notifications(ACPMethod.sessionCancel) == [["sessionId": "s-new"]])
        #expect(harness.session.client == nil)
        #expect(harness.session.connection == nil)
    }

    @Test func aBoundedShutdownStopsAnAgentThatDoesNotExit() async throws {
        let harness = ChatHarness(exits: false)
        try await harness.start()
        try await harness.send("Work")
        await harness.session.shutDown(exitWithin: .milliseconds(50))
        #expect(harness.terminations.withLock { $0 } == 1)
    }

    @Test func aBoundedShutdownLeavesAnAgentThatExitsAlone() async throws {
        let harness = ChatHarness()
        try await harness.start()
        await harness.session.shutDown(exitWithin: .milliseconds(50))
        #expect(harness.terminations.withLock { $0 } == 0)
    }

    // MARK: Answers that arrive too late

    @Test func aSettingAnsweredAfterTheChatMovedOnIsIgnored() async throws {
        var script = ScriptedAgent.Script()
        script.setConfigOption = .silent
        let harness = ChatHarness(script: script)
        try await harness.start()
        let change = Task { await harness.session.setControl("model", to: "fast") }
        let agent = try harness.agent()
        try await waitUntil("the change is asked for") { !agent.requests(ACPMethod.sessionSetConfigOption).isEmpty }
        // The request fails as the connection closes, after the chat already ended: no notice
        // about a setting of a session that is gone.
        await harness.session.shutDown()
        await change.value
        #expect(harness.session.notice == nil)
    }

    // MARK: Attachments

    @Test func anImageThatCannotBeReadGoesAsALink() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("chatui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("locked.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: image.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path) }

        var script = ScriptedAgent.Script()
        script.initialize = .result(ScriptedAgent.initializeResult(image: true))
        let harness = ChatHarness(script: script)
        try await harness.start()
        let agent = try harness.agent()
        harness.session.addAttachments([image])
        #expect(harness.session.send())
        // The bubble is there before the prompt is even built.
        #expect(harness.session.transcript.items.count == 1)
        try await waitUntil("the prompt arrives") { !agent.requests(ACPMethod.sessionPrompt).isEmpty }
        let prompt = try #require(agent.requests(ACPMethod.sessionPrompt).first?.params["prompt"]?.arrayValue)
        #expect(prompt.map { $0["type"] } == ["resource_link"])
        await harness.session.shutDown()
    }
}
