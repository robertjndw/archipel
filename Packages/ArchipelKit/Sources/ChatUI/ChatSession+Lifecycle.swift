import ACPKit
import ArchipelCore
import Foundation

extension ChatSession {
    // MARK: Starting

    /// Installs the agent if needed, starts it and opens the conversation: the one to restore
    /// when the configuration names one, a new one otherwise. Returns once the chat is ready or
    /// failed. Call once; `retry()` starts again after a failure.
    public func start() async {
        guard let configuration, !hasStarted, !isShuttingDown else { return }
        hasStarted = true
        await runStart(restoring: configuration.existingAgentSessionID)
    }

    /// Starts over after `phase` became `.failed` or `.ended`, such as after a terminal sign-in or
    /// a crash. Restores the conversation when there is one worth restoring, and resends a prompt
    /// that was refused for want of a sign-in.
    public func retry() async {
        guard let configuration, hasStarted, !isShuttingDown else { return }
        switch phase {
        case .failed, .ended: break
        case .starting, .ready: return
        }
        let restoring: String? = if isAgentSessionIDConfirmed {
            agentSessionID
        } else if let restoringID {
            // A restore that never finished, which the user still expects back.
            restoringID
        } else if agentSessionID == nil {
            configuration.existingAgentSessionID
        } else {
            // A new session that never saw a prompt: nothing in it to restore.
            nil
        }
        discardClient()
        await runStart(restoring: restoring)
    }

    /// Runs `launch` as a task of its own that `cancelStart()` can cancel wherever it waits.
    /// Cancelling the caller cancels it too.
    private func runStart(restoring existingID: String?) async {
        startTask?.cancel()
        let task = Task { await self.launch(restoring: existingID) }
        startTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if startTask == task { startTask = nil }
    }

    /// Stops starting, wherever it is: installing, connecting, opening the conversation or
    /// signing in. A sign-in goes back to asking; anything else ends in a failure with Try Again.
    public func cancelStart() {
        guard configuration != nil, !isShuttingDown, case let .starting(step) = phase else { return }
        if step == .signingIn {
            cancelSignIn()
        } else {
            abandonStart(message: "Starting \(agentName) was canceled.")
        }
    }

    /// Gives up on the start under way: whatever it was waiting for is cancelled or fails, since
    /// the agent is stopped, and the chat shows a failure with Try Again. The start's own code
    /// finds itself out of date after its await and returns without reporting anything.
    func abandonStart(message: String) {
        let details = stderrTail()
        generation += 1
        signInAttempt += 1
        startTask?.cancel()
        startTask = nil
        discardClient()
        fail(ChatFailure(reason: .couldNotStart, title: "Could Not Start \(agentName)", message: message, details: details))
    }

    /// Gives the agent `limit` to answer `request`, a step of the start. When it does not, the
    /// start is abandoned; that stops the agent, which fails `request` through the closed
    /// connection, so nothing is left waiting and nothing is resumed twice.
    func withDeadline<Result>(_ limit: Duration, launchID: Int, _ request: () async throws -> Result) async throws -> Result {
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: limit)
            } catch {
                return
            }
            guard let self, self.isCurrent(launchID) else { return }
            self.abandonStart(message: "\(self.agentName) didn't respond.")
        }
        defer { timer.cancel() }
        return try await request()
    }

    func launch(restoring existingID: String?) async {
        guard let configuration else { return }
        generation += 1
        let launchID = generation
        phase = .starting(.preparing)
        notice = nil
        // A refused prompt survives a restart and goes out once the chat is ready; a refused
        // session setup is done again by this launch.
        if case .openSession = pendingRetry { pendingRetry = nil }

        // Progress goes through a stream so it is shown in the order it was reported, which
        // separate main actor tasks would not promise.
        let (progressUpdates, progressSink) = AsyncStream.makeStream(of: ChatLauncher.Progress.self, bufferingPolicy: .unbounded)
        let progressDisplay = Task { [weak self] in
            for await progress in progressUpdates {
                guard let self, self.isCurrent(launchID), case .starting = self.phase else { continue }
                self.showLaunchProgress(progress)
            }
        }
        let launch: ChatLaunch
        do {
            launch = try await configuration.resolveLaunch { progressSink.yield($0) }
            progressSink.finish()
            await progressDisplay.value
        } catch {
            progressSink.finish()
            await progressDisplay.value
            guard isCurrent(launchID) else { return }
            fail(launchFailure(error))
            return
        }
        guard isCurrent(launchID) else { return }

        phase = .starting(.connecting)
        let connection: ChatAgentConnection
        do {
            connection = try configuration.connect(launch, configuration.workingDirectory)
        } catch {
            fail(ChatFailure(
                reason: .couldNotStart, title: "Could Not Start \(agentName)",
                message: error.localizedDescription
            ))
            return
        }
        let client = ACPClient(transport: connection.transport)
        let inbox = EventInbox()
        self.client = client
        self.connection = connection
        self.inbox = inbox
        closeReason = nil
        startReading(client, into: inbox)

        let response: InitializeResponse
        do {
            response = try await withDeadline(configuration.timing.request, launchID: launchID) {
                try await client.initialize(clientInfo: configuration.clientInfo)
            }
        } catch {
            guard isCurrent(launchID) else { return }
            if case let .unsupportedProtocolVersion(version) = error as? ACPError {
                discardClient()
                fail(ChatFailure(
                    reason: .unsupportedProtocolVersion(version),
                    title: "This Version of \(agentName) Is Not Supported",
                    message: "\(agentName) uses chat protocol version \(version), but Archipel supports version \(ACPClient.protocolVersion). Updating Archipel or \(agentName) may help."
                ))
            } else {
                failToStart(error)
            }
            return
        }
        guard isCurrent(launchID) else { return }
        agentInfo = response.agentInfo
        agentCapabilities = response.agentCapabilities
        promptCapabilities = response.agentCapabilities.promptCapabilities
        authMethods = response.authMethods

        await openSession(restoring: existingID, launchID: launchID)
    }

    private func showLaunchProgress(_ progress: ChatLauncher.Progress) {
        switch progress {
        case .checkingRegistry:
            phase = .starting(.preparing)
        case let .downloading(fraction):
            phase = .starting(.installing(agentName: agentName, fraction: fraction))
        case .installingPackages:
            phase = .starting(.installing(agentName: agentName, fraction: nil))
        case .done:
            phase = .starting(.connecting)
        }
    }

    /// Restores `existingID` the best way the agent offers, falling back to a new session when
    /// the agent no longer knows it, and makes the chat ready.
    func openSession(restoring existingID: String?, launchID: Int) async {
        guard let client, let configuration else { return }
        let directory = configuration.workingDirectory
        let timing = configuration.timing
        restoringID = existingID
        do {
            var restored = false
            if let existingID, agentCapabilities.loadSession {
                phase = .starting(.restoringHistory)
                agentSessionID = existingID
                // The replay rebuilds the whole conversation; what is on screen from before a
                // retry would be shown twice otherwise.
                let previous = transcript
                transcript = ChatTranscript()
                isReplayPending = true
                do {
                    let setup = try await withDeadline(timing.loadSession, launchID: launchID) {
                        let setup = try await client.loadSession(id: existingID, cwd: directory)
                        await waitForReplayEnd()
                        return setup
                    }
                    guard isCurrent(launchID) else { return }
                    transcript.apply(setup)
                    isHistoryUnavailable = false
                    restored = true
                } catch {
                    await waitForReplayEnd()
                    guard isCurrent(launchID) else { return }
                    transcript = previous
                    guard Self.isMissingSession(error) else { throw error }
                }
            } else if let existingID, agentCapabilities.sessionCapabilities.resume {
                agentSessionID = existingID
                do {
                    let setup = try await withDeadline(timing.request, launchID: launchID) {
                        try await client.resumeSession(id: existingID, cwd: directory)
                    }
                    guard isCurrent(launchID) else { return }
                    transcript.apply(setup)
                    isHistoryUnavailable = transcript.items.isEmpty
                    restored = true
                } catch {
                    guard isCurrent(launchID) else { return }
                    guard Self.isMissingSession(error) else { throw error }
                }
            }

            if restored {
                isAgentSessionIDConfirmed = true
            } else {
                agentSessionID = nil
                let response = try await withDeadline(timing.request, launchID: launchID) {
                    try await client.newSession(cwd: directory)
                }
                guard isCurrent(launchID) else { return }
                agentSessionID = response.sessionId
                isAgentSessionIDConfirmed = false
                transcript.apply(response.setup)
                isHistoryUnavailable = existingID != nil && transcript.items.isEmpty
            }
        } catch {
            guard isCurrent(launchID) else { return }
            if (error as? ACPError)?.isAuthenticationRequired == true {
                // Codex refuses `session/new` until signed in.
                pendingRetry = .openSession(restoring: existingID)
                fail(signInFailure())
            } else {
                failToStart(error)
            }
            return
        }

        restoringID = nil
        phase = .ready
        var effects: [Event] = [.agent(.sessionStarted)]
        reportTitleAndUsage(into: &effects)
        emit(effects)
        if case let .prompt(blocks) = pendingRetry {
            pendingRetry = nil
            submit(blocks, showsBubble: false)
        }
    }

    /// Agents report a session they do not know in different ways (-32002, an internal error
    /// saying "not found", invalid params), so any refusal other than a sign-in request counts.
    /// A dead connection does not: there is nothing to fall back to then.
    static func isMissingSession(_ error: any Error) -> Bool {
        guard let error = error as? ACPError, case .rpc = error else { return false }
        return !error.isAuthenticationRequired
    }

    // MARK: Signing in

    /// Runs an agent-type sign-in method from `.failed` with `.signInRequired`, then carries on
    /// with what needed it: opening the session, or the prompt that was refused. Terminal-type
    /// methods are the app's to run; call `retry()` after them.
    public func authenticate(methodId: String) async {
        guard case let .failed(failure) = phase, case .signInRequired = failure.reason, !isShuttingDown else { return }
        guard let client, closeReason == nil else {
            await retry()
            return
        }
        let launchID = generation
        signInAttempt += 1
        let attempt = signInAttempt
        notice = nil
        phase = .starting(.signingIn)
        do {
            try await client.authenticate(methodId: methodId)
        } catch {
            guard isCurrent(launchID), attempt == signInAttempt else { return }
            if case .connectionClosed = error as? ACPError {
                failToStart(error)
                return
            }
            phase = .failed(failure)
            notice = "Signing in to \(agentName) didn't finish. \(Self.readableMessage(error))"
            return
        }
        guard isCurrent(launchID), attempt == signInAttempt else { return }
        let retry = pendingRetry
        pendingRetry = nil
        switch retry {
        case let .openSession(existingID):
            await openSession(restoring: existingID, launchID: launchID)
        case let .prompt(blocks):
            phase = .ready
            submit(blocks, showsBubble: false)
        case nil:
            phase = .ready
        }
    }

    /// Stops waiting for a sign-in started with `authenticate(methodId:)`, such as one in a
    /// browser the user gave up on, and asks again. There is no time limit on a sign-in, so this
    /// is the way out. The agent keeps running and may still finish the abandoned attempt; its
    /// answer is ignored, and signing in again asks it again.
    public func cancelSignIn() {
        guard case .starting(.signingIn) = phase, !isShuttingDown else { return }
        signInAttempt += 1
        notice = nil
        phase = .failed(signInFailure())
    }

    func signInFailure() -> ChatFailure {
        let agentMethods = authMethods.filter { $0.type == .agent }
        let terminalMethods = authMethods.filter { $0.type == .terminal }
        return ChatFailure(
            reason: .signInRequired(agentMethods: agentMethods, terminalMethods: terminalMethods),
            title: "Sign In to \(agentName)",
            message: "\(agentName) needs you to sign in before it can answer."
        )
    }

    // MARK: Stopping

    /// Ends the chat: cancels a running turn, closes the agent's input and gives it a few seconds
    /// to exit before stopping it. The transcript stays; no events are sent from here on.
    ///
    /// With `limit`, this returns once the agent exited or that much time passed, and sends
    /// SIGTERM to its process group if it is still running then. A restart needs that: it must not
    /// start a new agent on the same conversation while the old one may still be working on it.
    /// Without a limit, this returns when the agent is gone, after the usual grace period.
    public func shutDown(exitWithin limit: Duration? = nil) async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let client = self.client
        let connection = self.connection
        let runningSession = isTurnRunning ? agentSessionID : nil
        startTask?.cancel()
        endLocally()
        guard let client else { return }
        // Closing the input alone leaves an agent in the middle of a turn free to run tools
        // until it notices; Claude's adapter takes seconds to.
        if let runningSession { await client.cancel(sessionId: runningSession) }
        guard let limit, let connection else {
            await client.shutdown()
            return
        }
        // Goes on after this returns, escalating to SIGKILL if it has to.
        Task { await client.shutdown() }
        if await connection.waitForExit(limit) { return }
        connection.terminateNow()
        _ = await connection.waitForExit(.seconds(1))
    }

    /// Stops the agent at once without waiting, for app quit.
    public func terminateNow() {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        startTask?.cancel()
        connection?.terminateNow()
        endLocally()
    }

    private func endLocally() {
        inbox = nil
        replayEnded()
        if isTurnRunning { transcript.endTurn(nil) }
        endTurnState()
        // The process is stopped by whoever ended the chat; nothing here needs it any more.
        client = nil
        connection = nil
        if case .ended = phase { return }
        phase = .ended(ChatEnding(exitCode: nil, isClean: true, message: "This chat has ended."))
    }

    /// Lets go of the current client without hearing from it again, and stops its process.
    func discardClient() {
        let client = self.client
        self.client = nil
        connection = nil
        inbox = nil
        replayEnded()
        if isTurnRunning { transcript.endTurn(nil) }
        endTurnState()
        if let client {
            Task { await client.shutdown() }
        }
    }

    // MARK: Failing

    func fail(_ failure: ChatFailure) {
        phase = .failed(failure)
        emit(.failed(failure))
    }

    /// A start that broke after the process was spawned. The process is stopped, and its stderr
    /// usually says why.
    private func failToStart(_ error: any Error) {
        let details = stderrTail()
        let message: String = if let reason = closeReason ?? (error as? ACPError).flatMap(Self.closeReason) {
            reason == .endOfStream || reason == .closedByClient
                ? "\(agentName) quit while starting."
                : "\(agentName) quit while starting. \(reason.description)."
        } else {
            Self.readableMessage(error)
        }
        discardClient()
        fail(ChatFailure(reason: .couldNotStart, title: "Could Not Start \(agentName)", message: message, details: details))
    }

    private static func closeReason(_ error: ACPError) -> ACPCloseReason? {
        if case let .connectionClosed(reason) = error { reason } else { nil }
    }

    func launchFailure(_ error: any Error) -> ChatFailure {
        let message = Self.readableMessage(error)
        switch error as? ChatLaunchError {
        case .nodeMissing:
            return ChatFailure(
                reason: .nodeMissing, title: "Node.js Is Required",
                message: "\(agentName) needs Node.js to run as a chat. Install it from nodejs.org or with Homebrew, then try again."
            )
        case .notInRegistry, .unsupportedDistribution, .installFailed:
            return ChatFailure(reason: .installFailed, title: "Could Not Install \(agentName)", message: message)
        case .cliNotInstalled, .commandNotFound, .registryUnreachable, nil:
            return ChatFailure(reason: .couldNotStart, title: "Could Not Start \(agentName)", message: message)
        }
    }

    static func readableMessage(_ error: any Error) -> String {
        if case let .rpc(rpc) = error as? ACPError, !rpc.message.isEmpty { return rpc.message }
        return error.localizedDescription
    }
}
