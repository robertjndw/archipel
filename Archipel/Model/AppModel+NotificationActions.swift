import AgentKit
import AppKit
import ArchipelCore
import TerminalKit

extension AppModel {
    /// Agents leave key handling of a paste to the next read; pressing Return in the same instant
    /// can land in the paste and become a newline instead of sending the message.
    static let replySubmitDelay = Duration.milliseconds(150)
    /// How often to check whether screen sharing ended while notifications are held.
    static let sharingPollInterval = Duration.seconds(3)

    // MARK: Posting

    func deliverNotification(session: Session, activity: SessionActivity, title: String, subtitle: String) {
        if settings.holdsNotificationsWhileSharingScreen, ScreenSharingDetector.isSharing() {
            // What the session's older notification said is out of date, and the summary will cover it.
            notifier.clear(sessionID: session.id)
            notifier.held.hold(session.id)
            watchForSharingToEnd()
            return
        }
        notifier.post(
            sessionID: session.id,
            title: title,
            subtitle: subtitle,
            body: activity.lastMessage,
            playsSound: settings.playsNotificationSound,
            status: activity.status,
            category: notificationCategory(for: session, activity: activity)
        )
    }

    /// Buttons only where the app knows how to answer: Claude Code and Codex, not a shell or a script,
    /// which could take a reply as a command.
    private func notificationCategory(for session: Session, activity: SessionActivity) -> AttentionNotifier.Category? {
        guard session.agent == .claude || session.agent == .codex, scriptSessions[session.id] == nil else { return nil }
        switch activity.status {
        case .needsAttention(.permission):
            // Claude asks its multiple choice questions through the permission hook; they have no Yes and No.
            return activity.lastMessage == "AskUserQuestion" ? nil : .permission
        case .needsAttention(.question), .needsAttention(.idle), .finished:
            return .reply
        default:
            return nil
        }
    }

    // MARK: Answering

    /// Types the user's answer into the agent's terminal, without bringing Archipel forward. Anything
    /// that no longer matches what the notification was about opens the session instead, so the user
    /// sees what is really there rather than having a keypress land on a different prompt.
    func answer(_ response: AttentionNotifier.Response) {
        let id = response.sessionID
        let status = activity(for: id).status
        guard let session = workspace.session(id: id), session.agent == .claude || session.agent == .codex,
              scriptSessions[id] == nil, let terminal = terminals[id],
              notifier.isCurrent(response), AttentionNotifier.statusKey(status) == response.status
        else { return bringForward(id) }

        // The live grid, not the viewport: if the user scrolled back, the viewport may show an old,
        // already answered menu, or hide the one that is really waiting. Not being able to read it
        // at all means not knowing what a keypress would do.
        guard let screen = terminal.readActiveScreenText() else { return bringForward(id) }

        switch response.choice {
        case .allow, .deny:
            guard status == .needsAttention(.permission), let prompt = ApprovalPrompt.parse(screen: screen)
            else { return bringForward(id) }
            let allowing = if case .allow = response.choice { true } else { false }
            guard terminal.sendKey(TerminalKey(allowing ? prompt.allow : prompt.deny)) else { return bringForward(id) }
            // Denying makes both agents drop the turn and wait at their prompt.
            resolveAttention(of: id, to: allowing ? .working : .finished)

        case .reply(let text):
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            // A question can come as a menu (Claude's elicitation forms, for one), where pasted text
            // would be taken as choices and the Return after it would pick the focused row. Checked
            // whatever the status says, since a menu can appear after the notification was posted.
            if ApprovalPrompt.trailingMenu(in: screen) != nil {
                return bringForward(id)
            }
            terminal.sendText(message)
            Task { [weak self] in
                try? await Task.sleep(for: Self.replySubmitDelay)
                // A restart in the meantime would send Return to a fresh process.
                guard let self, self.terminals[id] === terminal else { return }
                terminal.sendKey(.enter)
            }
            resolveAttention(of: id, to: .working)
        }
    }

    private func bringForward(_ id: Session.ID) {
        NSApp.activate()
        select(session: id)
    }

    // MARK: Holding back while sharing

    private func watchForSharingToEnd() {
        guard notifier.holdWatch == nil else { return }
        notifier.holdWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sharingPollInterval)
                guard let self else { return }
                // Turning the setting off counts as the end, so nothing stays held indefinitely.
                if self.settings.holdsNotificationsWhileSharingScreen, ScreenSharingDetector.isSharing() { continue }
                self.notifier.holdWatch = nil
                self.releaseHeldNotifications()
                return
            }
        }
    }

    private func releaseHeldNotifications() {
        let held = notifier.held
        notifier.held.removeAll()
        guard let summary = held.summary(activities: activities), let target = summary.sessionID else { return }
        if settings.suppressesNotificationsWhileActive, NSApp.isActive { return }
        notifier.postSummary(
            title: "While you were busy",
            body: summary.text,
            sessionID: target,
            playsSound: settings.playsNotificationSound
        )
    }
}

private extension TerminalKey {
    init(_ key: PromptKey) {
        switch key {
        case .escape: self = .escape
        case .enter: self = .enter
        case .character(let character): self = .character(character)
        }
    }
}
