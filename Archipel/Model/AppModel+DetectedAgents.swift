import AgentKit
import ArchipelCore
import Foundation
import TerminalKit

/// Claude started by hand in a shell tab. The tab acts as a Claude session while Claude runs, with
/// its icon and status, and goes back to being a shell when Claude exits. The saved session stays a
/// shell throughout.
///
/// Scans of the terminal's foreground find any Claude, and its OSC 9;4 progress tells working
/// from idle. If the user installed Archipel's hooks into their Claude settings, those give the
/// same detail as for a session the app launched.
extension AppModel {
    // MARK: Effective agent

    func effectiveAgent(for session: Session) -> EffectiveAgent {
        EffectiveAgent.resolve(
            persisted: session.agent,
            runtime: isPlainShell(session) ? runtimeAgents[session.id]?.agent : nil
        )
    }

    func effectiveAgent(for id: Session.ID) -> EffectiveAgent? {
        workspace.session(id: id).map { effectiveAgent(for: $0) }
    }

    /// The agent each shell tab runs right now, for views that draw a session's icon.
    var agentOverrides: [Session.ID: AgentKind] {
        runtimeAgents.compactMapValues(\.agent?.kind)
    }

    /// A shell the user types into, not a script that only runs in one.
    func isPlainShell(_ session: Session) -> Bool {
        session.agent == .shell && scriptSessions[session.id] == nil
    }

    /// Whether text typed into the terminal now would reach the agent. Always true for an agent the
    /// app launched, since the terminal ends with it. A detected one can have exited or been
    /// suspended since the last scan, and then the shell would run the text as commands.
    func detectedAgentHoldsTerminal(_ id: Session.ID) -> Bool {
        guard let agent = effectiveAgent(for: id), agent.isDetected else { return true }
        guard let terminal = terminals[id], let group = terminal.foregroundProcessID else { return false }
        if let process = runtimeAgents[id]?.agent?.process {
            guard let entry = ProcessSampler.process(process.pid), entry.identity == process else { return false }
            return entry.processGroupID == group
        }
        return ProcessSampler.foregroundLeader(group: group).flatMap { AgentProcessMatcher.agent(forLabel: $0.label) } != nil
    }

    // MARK: Finding the agent

    /// Called after every resource scan. There is no separate timer.
    func reconcileDetectedAgents() {
        for (id, terminal) in terminals where !terminal.hasExited {
            guard let session = workspace.session(id: id), isPlainShell(session),
                  let observation = foregroundObservation(of: terminal, for: id)
            else { continue }
            record(observation, for: id)
        }
    }

    /// Checks one shell tab after a short delay instead of waiting for the next scan. Calls within
    /// the delay coalesce into one check.
    func checkForegroundSoon(_ id: Session.ID) {
        guard let session = workspace.session(id: id), isPlainShell(session) else { return }
        foregroundChecks[id]?.cancel()
        foregroundChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.foregroundChecks[id] = nil
            guard let terminal = self.terminals[id], !terminal.hasExited,
                  let session = self.workspace.session(id: id), self.isPlainShell(session),
                  let observation = self.foregroundObservation(of: terminal, for: id)
            else { return }
            self.record(observation, for: id)
        }
    }

    private func record(_ observation: ForegroundObservation, for id: Session.ID) {
        updateRuntimeAgent(id) { $0.observe(observation) }
        // Progress some other program left set, or a Claude killed mid-turn, would otherwise make
        // the next Claude found here look busy from the start.
        if observation.shellInForeground, runtimeAgents[id]?.agent == nil {
            progressTurns[id] = nil
            stopFollowingProgress(id)
        }
    }

    /// Nil when the terminal has no foreground process group, which only happens while it closes.
    private func foregroundObservation(of terminal: TerminalSession, for id: Session.ID) -> ForegroundObservation? {
        guard let group = terminal.foregroundProcessID else { return nil }
        // A few libproc calls per shell tab. The leader is the command the user typed. Checking it
        // also catches `exec claude`, which the scan skips because it has the shell's pid.
        let leader = ProcessSampler.foregroundLeader(group: group)
        if let leader, let kind = AgentProcessMatcher.agent(forLabel: leader.label) {
            return ForegroundObservation(agent: kind, process: leader.identity, shellInForeground: false)
        }
        if let leader, AgentProcessMatcher.isShell(label: leader.label) {
            return ForegroundObservation(shellInForeground: true)
        }
        // Behind a wrapper (npx, caffeinate) the agent is a member of the group but not its leader.
        // Only the last scan read the whole group, and its rows may be a few seconds old, so a row
        // counts only while its process is still in the foreground.
        let rows = resources.sessions[id]?.processes ?? []
        for row in rows where row.isForeground {
            guard let kind = AgentProcessMatcher.agent(forLabel: row.label),
                  let entry = ProcessSampler.process(row.id.pid), entry.identity == row.id, entry.processGroupID == group
            else { continue }
            return ForegroundObservation(agent: kind, process: row.id, shellInForeground: false)
        }
        return ForegroundObservation(shellInForeground: false)
    }

    // MARK: Transitions

    /// Reacts when the change makes the agent appear, leave or be replaced by a new run.
    func updateRuntimeAgent(_ id: Session.ID, _ change: (inout RuntimeAgentState) -> Void) {
        let before = runtimeAgents[id] ?? RuntimeAgentState()
        var after = before
        change(&after)
        // Most scans change nothing, and writing anyway would redraw the sidebar and tab bar.
        guard after != before else { return }
        runtimeAgents[id] = after
        switch (before.agent, after.agent) {
        case (nil, .some):
            agentAppeared(id)
        case (let old?, nil):
            agentLeft(id, kind: old.kind)
        case (let old?, let new?):
            if let oldProcess = old.process, let newProcess = new.process, oldProcess != newProcess {
                // Quit and restarted between two scans. Treat it as a new run.
                agentLeft(id, kind: old.kind)
                agentAppeared(id)
            } else if new.reportsThroughHooks {
                // Hooks are more precise than the progress reports, so stop following those.
                stopFollowingProgress(id)
            }
        case (nil, nil):
            break
        }
    }

    private func agentAppeared(_ id: Session.ID) {
        // Here and not at launch, for the same reason as in `ensureRunning`.
        notifier.requestAuthorizationIfNeeded()
        guard let before = activities[id] else { return }
        if case .exited = before.status { return }
        let hooked = runtimeAgents[id]?.agent?.reportsThroughHooks == true
        // The progress may have been set before a scan found the agent. Without hooks it is the
        // only sign that the agent is working, so keep it.
        let working = !hooked && progressTurns[id]?.isActive == true
        var activity = before
        activity.status = working ? .working : .finished
        activity.completedTurn = false
        commit(activity, replacing: before, of: id, viewed: isBeingViewed(id))
    }

    private func agentLeft(_ id: Session.ID, kind: AgentKind) {
        stopFollowingProgress(id)
        progressTurns[id] = nil
        // Drop them before the status changes. The status change is what delivers pending reviews,
        // and they would now be typed into the shell.
        if pendingReviews.removeValue(forKey: id) != nil {
            let title = workspace.session(id: id)?.displayTitle ?? "The session"
            problem = "\(title) is no longer running \(kind.definition.displayName), so the review comments were not sent. Your comments are kept."
        }
        apply(.agentLeft, to: id)
    }

    /// For a terminal that closed or exited. The agent went with the shell, so there is no
    /// transition to report.
    func forgetRuntimeAgent(_ id: Session.ID) {
        foregroundChecks.removeValue(forKey: id)?.cancel()
        stopFollowingProgress(id)
        progressTurns[id] = nil
        if runtimeAgents[id] != nil { runtimeAgents[id] = nil }
    }

    // MARK: Hooks from the user's settings

    func receiveUserSettingsHook(_ message: HookMessage, for id: Session.ID) {
        let sender = hookSender(message.ancestorPIDs)
        switch message.lifecycle {
        case .started(let source)?:
            updateRuntimeAgent(id) {
                $0.hookStarted(agentSessionID: message.agentSessionID, source: source, sender: sender)
            }
            if let sender, runtimeAgents[id]?.agent?.agentSessionID == message.agentSessionID {
                updateRuntimeAgent(id) { $0.attach(sender) }
            }
            // Older helpers send no ancestors, so a scan has to find the process.
            checkForegroundSoon(id)
        case .ended(let reason)?:
            updateRuntimeAgent(id) {
                $0.hookEnded(agentSessionID: message.agentSessionID, reason: reason, sender: sender)
            }
        case nil:
            guard let event = message.event else { return }
            var accepted = false
            updateRuntimeAgent(id) { accepted = $0.hookEvent(agentSessionID: message.agentSessionID, sender: sender) }
            guard accepted else { return }
            if let sender { updateRuntimeAgent(id) { $0.attach(sender) } }
            // The conversation id is not saved. The session is a shell, and resuming the
            // conversation on the next launch would start Claude where the user asked for a shell.
            apply(event, to: id)
        }
    }

    /// The nearest Claude above the hook helper. Finding the tab's Claude anywhere in the chain is
    /// not enough, since a `claude -p` it runs has it there too. Claude runs hooks through a shell,
    /// so the match is usually the second pid.
    private func hookSender(_ ancestors: [Int32]) -> ProcessIdentity? {
        for pid in ancestors {
            guard let entry = ProcessSampler.process(pid) else { continue }
            let (name, arguments) = ProcessSampler.name(of: pid)
            if AgentProcessMatcher.agent(forLabel: ProcessLabel.label(name: name, arguments: arguments)) != nil {
                return entry.identity
            }
        }
        return nil
    }

    // MARK: Progress, for an agent without hooks

    func receiveProgress(_ progress: TerminalProgress?, for id: Session.ID) {
        guard let session = workspace.session(id: id), isPlainShell(session) else { return }
        let active = switch progress?.state {
        case .normal?, .indeterminate?, .paused?: true
        case .error?, nil: false
        }
        // Kept even before an agent is found, so a turn that started before the scan is not lost.
        var turn = progressTurns[id] ?? ProgressTurn()
        let change = turn.receive(active: active, at: .now)
        progressTurns[id] = turn

        guard let agent = runtimeAgents[id]?.agent else {
            if change == .started { checkForegroundSoon(id) }
            return
        }
        guard !agent.reportsThroughHooks else { return }
        switch change {
        case .none:
            break
        case .started:
            progressChecks.removeValue(forKey: id)?.cancel()
            apply(.activity, to: id)
        case .mayHaveEnded(let checkAt):
            scheduleProgressCheck(id, at: checkAt)
        }
    }

    private func stopFollowingProgress(_ id: Session.ID) {
        progressChecks.removeValue(forKey: id)?.cancel()
    }

    private func scheduleProgressCheck(_ id: Session.ID, at date: Date) {
        progressChecks[id]?.cancel()
        progressChecks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            await self.checkProgressTurn(id)
        }
    }

    /// Decides whether a cleared progress ended the turn, asked for something, or only paused.
    private func checkProgressTurn(_ id: Session.ID) async {
        guard let turn = progressTurns[id], !turn.isActive, turn.clearedAt != nil,
              let agent = runtimeAgents[id]?.agent, !agent.reportsThroughHooks,
              activity(for: id).status == .working,
              let terminal = terminals[id]
        else { return }
        let group = terminal.foregroundProcessID
        let toolRunning = await Task.detached(priority: .utility) {
            Self.hasToolProcess(under: agent.process, inGroup: group, startedSince: turn)
        }.value
        // State may have changed while the process table was read off the main actor.
        guard !Task.isCancelled, progressTurns[id] == turn, terminals[id] === terminal,
              runtimeAgents[id]?.agent?.reportsThroughHooks == false
        else { return }
        // The live grid, not the viewport, for the reason given in `answer(_:)`.
        let screen = terminal.readActiveScreenText()
        let outcome = turn.decide(
            at: .now,
            toolProcessStartedSinceClear: toolRunning,
            screenShowsPrompt: screen.flatMap(ApprovalPrompt.parse(screen:)) != nil,
            screenShowsMenu: screen.flatMap(ApprovalPrompt.trailingMenu(in:)) != nil,
            status: activity(for: id).status
        )
        switch outcome {
        case .keepWorking(let recheckAt):
            scheduleProgressCheck(id, at: recheckAt)
        case .finished:
            progressChecks[id] = nil
            apply(.turnFinished(message: nil), to: id)
        case .needsAttention(let reason):
            progressChecks[id] = nil
            apply(.attentionRequested(reason, message: nil), to: id)
        case .ignore:
            progressChecks[id] = nil
        }
    }

    /// Looks for a Bash tool call: a descendant of the agent in the foreground group, started
    /// after the clear. MCP servers and background shells from earlier turns are older or in
    /// another group, so they don't count.
    nonisolated private static func hasToolProcess(
        under agent: ProcessIdentity?,
        inGroup group: Int32?,
        startedSince turn: ProgressTurn
    ) -> Bool {
        guard let agent, let group else { return false }
        let processes = ProcessSampler.processes()
        var children: [Int32: [ProcessEntry]] = [:]
        for process in processes { children[process.parentPID, default: []].append(process) }
        guard processes.contains(where: { $0.identity == agent }) else { return false }
        var queue = children[agent.pid] ?? []
        var seen: Set<Int32> = []
        while let process = queue.popLast() {
            guard seen.insert(process.pid).inserted else { continue }
            let started = TimeInterval(process.identity.startTime) / 1_000_000
            if process.processGroupID == group, turn.startedSinceClear(started) { return true }
            queue += children[process.pid] ?? []
        }
        return false
    }
}
