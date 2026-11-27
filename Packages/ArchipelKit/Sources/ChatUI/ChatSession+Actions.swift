import ACPKit
import ArchipelCore
import Foundation
import UniformTypeIdentifiers

extension ChatSession {
    // MARK: Sending

    /// Sends the draft and attachments as a prompt: shows it at once, clears the composer and
    /// starts the turn. While a turn runs the prompt is queued behind it instead. Returns false,
    /// changing nothing, when neither `canSend` nor `canQueue` is true.
    ///
    /// Images are read off the main actor, so the prompt goes out a moment after the bubble shows.
    @discardableResult
    public func send() -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        if canQueue {
            queuedPrompts.append(QueuedPrompt(text: text, attachments: files))
        } else {
            guard canSend, submit(text: text, files: files) else { return false }
        }
        draft = ""
        attachments = []
        return true
    }

    /// Takes a queued prompt back out, to drop it or to edit it in the composer.
    @discardableResult
    public func removeQueuedPrompt(_ id: QueuedPrompt.ID) -> QueuedPrompt? {
        guard let index = queuedPrompts.firstIndex(where: { $0.id == id }) else { return nil }
        return queuedPrompts.remove(at: index)
    }

    /// Puts the newest queued prompt back into the empty composer, to change it before it goes out.
    public func editLastQueuedPrompt() {
        guard draft.isEmpty, attachments.isEmpty, let prompt = queuedPrompts.popLast() else { return }
        draft = prompt.text
        attachments = prompt.attachments
    }

    /// Sends the oldest queued prompt, once nothing runs. False when there was none to send.
    @discardableResult
    func sendNextQueuedPrompt() -> Bool {
        guard canAcceptPrompt, let prompt = queuedPrompts.first, submit(text: prompt.text, files: prompt.attachments) else { return false }
        queuedPrompts.removeFirst()
        return true
    }

    /// Gives what is queued back to the composer, ahead of what is being typed. A turn that was
    /// stopped or failed should not be followed by prompts written while it still looked fine.
    func returnQueueToDraft() {
        guard !queuedPrompts.isEmpty else { return }
        let texts = queuedPrompts.map(\.text) + [draft]
        draft = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        let files = queuedPrompts.flatMap(\.attachments) + attachments
        attachments = []
        addAttachments(files)
        queuedPrompts = []
    }

    private func submit(text: String, files: [URL]) -> Bool {
        // The bubble names the files; it never needs their data.
        var bubble: [ContentBlock] = text.isEmpty ? [] : [.text(text)]
        bubble += files.map { Self.linkBlock(for: $0) }
        let acceptsImages = promptCapabilities.image
        return submit(showing: bubble) {
            await Task.detached(priority: .userInitiated) {
                Self.promptBlocks(text: text, attachments: files, acceptsImages: acceptsImages)
            }.value
        }
    }

    /// Sends `text` as a prompt on the app's behalf, such as review comments or a reply from a
    /// notification, leaving the draft alone. Returns false when the chat cannot take a prompt now.
    @discardableResult
    public func send(text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAcceptPrompt, !text.isEmpty else { return false }
        return submit([.text(text)], showsBubble: true)
    }

    @discardableResult
    func submit(_ blocks: [ContentBlock], showsBubble: Bool) -> Bool {
        submit(showing: showsBubble ? blocks : nil) { blocks }
    }

    /// Starts a turn at once and sends the prompt `makeBlocks` builds. Until the prompt is out the
    /// turn already counts as running, so no second prompt can overtake it.
    private func submit(showing bubble: [ContentBlock]?, prompt makeBlocks: @escaping @Sendable () async -> [ContentBlock]) -> Bool {
        guard let client, let sessionID = agentSessionID, canAcceptPrompt else { return false }
        if let bubble { transcript.appendUserPrompt(bubble) }
        turnError = nil
        notice = nil
        isTurnRunning = true
        isCancelling = false
        turnCount += 1
        let turn = turnCount
        // The first update of every turn is reported, however close to the last turn's.
        lastActivityReport = nil
        emit(.agent(.promptSubmitted))
        let launchID = generation
        Task {
            let blocks = await makeBlocks()
            // Stopped, or the agent lost, while the prompt was being put together.
            guard isCurrent(launchID), self.client === client, isTurnRunning, turnCount == turn else { return }
            if isCancelling {
                transcript.endTurn(.cancelled)
                endTurnState()
                emit(.agent(.turnFinished(message: nil)))
                return
            }
            runningPrompt = blocks
            do {
                try await client.prompt(sessionId: sessionID, blocks: blocks)
            } catch {
                // Only a closed connection gets here, and `.closed` ends the turn with its reason.
                // A client replaced meanwhile is not this turn's business either.
                guard isCurrent(launchID), self.client === client, isTurnRunning, closeReason == nil else { return }
                transcript.endTurn(nil)
                endTurnState()
                turnError = Self.readableTurnError((error as? ACPError) ?? .encodingFailed(error.localizedDescription))
                emit(.agent(.turnFinished(message: nil)))
            }
        }
        return true
    }

    /// Images over this size go as links, so a stray screenshot cannot blow up one message.
    nonisolated static let maximumInlineImageBytes = 10 << 20

    /// The image formats that go out inline. Adapters pass the media type on as is and the model
    /// refuses a prompt with any other, so an SVG or HEIC goes as a link instead.
    private nonisolated static let inlineImageTypes: Set<UTType> = [.png, .jpeg, .gif, .webP]

    /// Reads image files, so call it off the main actor. A file that cannot be read goes as a link.
    nonisolated static func promptBlocks(text: String, attachments: [URL], acceptsImages: Bool) -> [ContentBlock] {
        var blocks: [ContentBlock] = []
        if !text.isEmpty { blocks.append(.text(text)) }
        blocks += attachments.map { block(for: $0, acceptsImages: acceptsImages) }
        return blocks
    }

    private nonisolated static func block(for url: URL, acceptsImages: Bool) -> ContentBlock {
        let type = UTType(filenameExtension: url.pathExtension)
        if acceptsImages, let type, inlineImageTypes.contains(type), let mimeType = type.preferredMIMEType,
           let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maximumInlineImageBytes,
           let data = try? Data(contentsOf: url)
        {
            return .image(data: data.base64EncodedString(), mimeType: mimeType, uri: url.absoluteString)
        }
        return linkBlock(for: url)
    }

    nonisolated static func linkBlock(for url: URL) -> ContentBlock {
        .resourceLink(ResourceLink(uri: url.absoluteString, name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType))
    }

    /// Adds files to the next prompt, skipping ones already there.
    public func addAttachments(_ urls: [URL]) {
        for url in urls where !attachments.contains(url) {
            attachments.append(url)
        }
    }

    public func removeAttachment(_ url: URL) {
        attachments.removeAll { $0 == url }
    }

    // MARK: Stopping a turn

    /// Asks the agent to stop the running turn. Open permission requests are answered as
    /// cancelled. The turn goes on showing updates until the agent confirms it ended.
    ///
    /// An agent that is still at it `Timing.cancelGrace` later sets `isCancelIgnored`, and calling
    /// this again then stops the agent and ends the chat: it can no longer be trusted to be in
    /// any particular state, and a turn that goes on in the background would be worse.
    public func cancel() async {
        guard isTurnRunning, let client, let agentSessionID, let configuration else { return }
        if isCancelling {
            if isCancelIgnored { stopUnresponsiveAgent() }
            return
        }
        isCancelling = true
        permissionRequests.removeAll()
        let turn = turnCount
        let grace = configuration.timing.cancelGrace
        cancelGraceTask = Task { [weak self] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return
            }
            guard let self, self.isTurnRunning, self.isCancelling, self.turnCount == turn else { return }
            self.isCancelIgnored = true
        }
        await client.cancel(sessionId: agentSessionID)
    }

    private func stopUnresponsiveAgent() {
        let client = self.client
        let connection = self.connection
        // Nothing more from this agent is wanted, not even its exit.
        inbox = nil
        self.client = nil
        self.connection = nil
        transcript.endTurn(.cancelled)
        transcript.endBackgroundWork()
        endTurnState()
        phase = .ended(ChatEnding(exitCode: nil, isClean: true, message: "\(agentName) was stopped."))
        emit(.agent(.processExited(code: Self.exitCode(reportedFor: .closedByClient))))
        connection?.terminateNow()
        if let client {
            Task { await client.shutdown() }
        }
    }

    // MARK: Permissions

    /// Answers a permission request with one of its options. When more are queued, the owner
    /// hears about the next one as it heard about the first, since the chat still waits.
    public func respond(to request: ChatPermissionRequest, optionId: String) async {
        guard let index = permissionRequests.firstIndex(where: { $0.id == request.id }) else { return }
        permissionRequests.remove(at: index)
        switch request.options.first(where: { $0.optionId == optionId })?.kind {
        case .rejectOnce, .rejectAlways:
            // Agents need not report a refused call (Codex never does), and the status line
            // would name it as running for the rest of the turn. One that does report it wins.
            transcript.markToolCallCancelled(id: request.toolCall.toolCallId)
        default:
            break
        }
        if let next = permissionRequests.first {
            emit(Self.attentionEvent(for: next))
        } else {
            emit(.agent(.activity))
        }
        await client?.respond(toPermission: request.id, with: .selected(optionId: optionId))
    }

    // MARK: Settings

    /// The agent's settings for the composer, mode first, then model, then the rest in the
    /// agent's order. Built from config options; an agent that sends none but has legacy modes
    /// gets one "Mode" control with `ChatControl.modeFallbackID`.
    public var controls: [ChatControl] {
        let options = transcript.configOptions
        if options.isEmpty {
            guard !transcript.availableModes.isEmpty else { return [] }
            let choices = transcript.availableModes.map { ConfigOptionValue(value: $0.id, name: $0.name, description: $0.description) }
            return [ChatControl(
                id: ChatControl.modeFallbackID, name: "Mode", category: .mode,
                value: .select(current: transcript.currentModeId, groups: [ChatControl.ChoiceGroup(name: nil, choices: choices)])
            )]
        }
        func rank(_ category: ConfigOptionCategory?) -> Int {
            switch category {
            case .mode: 0
            case .model: 1
            case .modelConfig, .thoughtLevel: 2
            default: 3
            }
        }
        let ordered = options.enumerated().sorted { a, b in
            let (left, right) = (rank(a.element.category), rank(b.element.category))
            return left != right ? left < right : a.offset < b.offset
        }
        return ordered.map { Self.control(for: $0.element) }
    }

    static func control(for option: SessionConfigOption) -> ChatControl {
        let value: ChatControl.Value
        switch option.type {
        case .boolean:
            value = .toggle(option.currentValue.boolValue ?? false)
        case .select:
            let groups: [ChatControl.ChoiceGroup] = switch option.options {
            case let .flat(values): [ChatControl.ChoiceGroup(name: nil, choices: values)]
            case let .grouped(groups): groups.map { ChatControl.ChoiceGroup(name: $0.name, choices: $0.options) }
            }
            let current = option.currentValue.stringValue
            let isChoice = groups.contains { $0.choices.contains { $0.value == current } }
            value = .select(current: isChoice ? current : nil, groups: groups)
        }
        return ChatControl(id: option.id, name: option.name, description: option.description, category: option.category, value: value)
    }

    /// Picks a choice of a select control. The agent's answer, not a guess, updates the state.
    public func setControl(_ controlID: String, to value: String) async {
        await changeSetting(controlID, value: .string(value))
    }

    /// Turns a toggle control on or off.
    public func setControl(_ controlID: String, isOn: Bool) async {
        await changeSetting(controlID, value: .bool(isOn))
    }

    private func changeSetting(_ controlID: String, value: JSONValue) async {
        guard let client, let agentSessionID else { return }
        notice = nil
        let name = controls.first { $0.id == controlID }?.name ?? "this setting"
        let launchID = generation
        // An answer from an agent replaced meanwhile, by a retry or a restart, is about a session
        // that is gone.
        func isStillCurrent() -> Bool {
            isCurrent(launchID) && self.client === client && self.agentSessionID == agentSessionID
        }
        do {
            if controlID == ChatControl.modeFallbackID {
                guard let modeID = value.stringValue else { return }
                try await client.setMode(sessionId: agentSessionID, modeId: modeID)
                guard isStillCurrent() else { return }
                // No `current_mode_update` follows `session/set_mode`.
                transcript.setCurrentMode(modeID)
            } else {
                let options = try await client.setConfigOption(sessionId: agentSessionID, configId: controlID, value: value)
                guard isStillCurrent() else { return }
                if options.isEmpty {
                    // An agent that answers `{}` still made the change.
                    var updated = transcript.configOptions
                    if let index = updated.firstIndex(where: { $0.id == controlID }) { updated[index].currentValue = value }
                    transcript.setConfigOptions(updated)
                } else {
                    transcript.setConfigOptions(options)
                }
            }
        } catch {
            guard isStillCurrent() else { return }
            if (error as? ACPError)?.code == JSONRPCError.methodNotFound {
                notice = "\(agentName) can't change \(name.lowercased()) from here."
            } else {
                notice = "Couldn't change \(name.lowercased()). \(Self.readableMessage(error))"
            }
        }
    }

    public func dismissNotice() {
        notice = nil
    }

    /// Asks the chat view to put the cursor in the composer.
    public func requestComposerFocus() {
        composerFocusRequests += 1
    }
}
