import ACPKit
import AgentKit
import AppKit
import ArchipelCore
import ChatUI
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
            // A request without a summary must not borrow the text of whatever came before it.
            body: activity.pendingRequest.map(\.summary) ?? activity.lastMessage,
            playsSound: settings.playsNotificationSound,
            status: activity.status,
            request: activity.pendingRequest,
            category: notificationCategory(for: session, activity: activity)
        )
    }

    /// Buttons only where the app knows how to answer: an agent prompt, not a shell or a script (which
    /// always runs as one), since those could take a reply as a command.
    private func notificationCategory(for session: Session, activity: SessionActivity) -> AttentionNotifier.Category? {
        let agent = effectiveAgent(for: session)
        guard agent.acceptsPrompts else { return nil }
        // A banner that does not show all of what is asked, or cannot say which of several
        // prompts the terminal is on, only opens the session.
        if activity.needsUser, !activity.canAnswerUnseen { return nil }
        switch activity.status {
        case .needsAttention(.permission):
            if let chat = chats[session.id] {
                return chat.permissionRequests.first.flatMap(Self.allowAndDeny) == nil ? nil : .permission
            }
            // An agent whose prompt we cannot read gets a notification that only opens the session.
            guard agent.adapter.capabilities.answersApprovalsInTerminal else { return nil }
            // Claude asks its multiple choice questions through the permission hook; they have no Yes and No.
            return activity.lastMessage?.hasPrefix("AskUserQuestion") == true ? nil : .permission
        case .needsAttention(.question), .finished:
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
        let current = activity(for: id)
        let status = current.status
        guard let session = workspace.session(id: id), effectiveAgent(for: session).acceptsPrompts,
              notifier.isCurrent(response), AttentionNotifier.statusKey(status) == response.status,
              // The banner named one request. Another may have taken its place without the status
              // changing, and the key would then answer something the user never read.
              notifier.request(answeredBy: response) == current.pendingRequest,
              !current.needsUser || current.canAnswerUnseen
        else { return bringForward(id) }
        if let chat = chats[id] { return answer(response, in: chat, status: status) }
        guard let terminal = terminals[id],
              // A hand-started Claude may have exited since, and the shell would run the answer as a command.
              detectedAgentHoldsTerminal(id)
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
                // A restart in the meantime would send Return to a fresh process, and if a hand-started
                // Claude exited, the shell would run the reply as a command.
                guard let self, self.terminals[id] === terminal, self.detectedAgentHoldsTerminal(id) else { return }
                terminal.sendKey(.enter)
            }
            resolveAttention(of: id, to: .working)
        }
    }

    /// A chat's request carries its own options, so there is no screen to read and nothing to type.
    private func answer(_ response: AttentionNotifier.Response, in chat: ChatSession, status: SessionStatus) {
        let id = response.sessionID
        switch response.choice {
        case .allow, .deny:
            guard status == .needsAttention(.permission), let request = chat.permissionRequests.first,
                  let options = Self.allowAndDeny(request)
            else { return bringForward(id) }
            let allowing = if case .allow = response.choice { true } else { false }
            Task { await chat.respond(to: request, optionId: allowing ? options.allow : options.deny) }
            // Working either way: some agents carry on after a denial and others end the turn, and
            // the chat reports which.
            resolveAttention(of: id, to: .working)

        case .reply(let text):
            let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else { return }
            // A chat that is starting, signed out or busy takes no prompt, and the user should see why.
            guard chat.send(text: message) else { return bringForward(id) }
            resolveAttention(of: id, to: .working)
        }
    }

    /// The options behind Allow and Deny. Only a request offering both a one-time allow and a
    /// one-time reject gets the buttons: "always" choices change the agent's rules, which a button
    /// in a notification should not do behind the user's back.
    private static func allowAndDeny(_ request: ChatPermissionRequest) -> (allow: String, deny: String)? {
        guard let allow = request.options.first(where: { $0.kind == .allowOnce }),
              let deny = request.options.first(where: { $0.kind == .rejectOnce })
        else { return nil }
        return (allow.optionId, deny.optionId)
    }

    private func bringForward(_ id: Session.ID) {
        showMainWindow()
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
            covering: summary.covered,
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
