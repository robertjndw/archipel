import ACPKit
import AgentKit
import AppKit
import ArchipelCore
import ChatUI
import TerminalKit

/// Where chat agents come from: the registry index and the adapters installed from it. One of each
/// for the whole app, so two chats starting the same agent share one download.
struct ChatAgentSources {
    let registry: ACPRegistryStore
    let installer: ACPInstaller

    /// `ARCHIPEL_ACP_REGISTRY` replaces the registry's address, so UI tests can serve a `file://`
    /// index with stub agents instead of reaching the network. Never in a release build: whoever
    /// sets the variable would decide what the app downloads and runs.
    init(supportDirectory support: URL) {
        #if DEBUG || UITESTS
        let override = ProcessInfo.processInfo.environment["ARCHIPEL_ACP_REGISTRY"].flatMap(URL.init(string:))
        #else
        let override: URL? = nil
        #endif
        registry = ACPRegistryStore(
            cacheDirectory: support.appending(path: "acp-registry", directoryHint: .isDirectory),
            indexURL: override ?? ACPRegistryStore.defaultIndexURL
        )
        installer = ACPInstaller(root: support.appending(path: "acp-agents", directoryHint: .isDirectory))
    }
}

/// Sessions shown as a chat over the Agent Client Protocol instead of in a terminal. The chat reports
/// the same `AgentEvent`s hooks do, so status, notifications and attention need nothing of their own.
extension AppModel {
    static let chatClientInfo = Implementation(
        name: "archipel",
        title: "Archipel",
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    )

    // MARK: Launching

    /// The chat half of `ensureRunning`, which has already marked the session as launched and counted
    /// this launch as `launch`.
    func launchChat(_ id: Session.ID, adapter: any AgentAdapter, in worktree: Worktree, launch: Int?) {
        guard chatAgents != nil, let support = adapter.acp else { return }
        SidebarTips.chatOpened()
        Task { [self] in
            let path = await loginPATH.value
            await waitForStoppingChat(of: id)
            // The same checks as a terminal launch. Nothing is awaited between them and storing the
            // chat, so a launch that went stale meanwhile never gets as far as starting a process.
            guard launch == launchGenerations[id], chats[id] == nil, terminals[id] == nil,
                  let session = workspace.session(id: id)
            else { return }
            guard FileManager.default.fileExists(atPath: worktree.path.path) else {
                launchFailures[id] = "The folder \(worktree.path.path) no longer exists."
                apply(.processExited(code: 1), to: id)
                return
            }
            let chosen = settings.executablePath(for: adapter.id).map { Self.locateExecutable(adapter, override: $0, inPATH: path) }
            // A chosen CLI that is gone is only a problem when the chat runs it. Codex's adapter
            // brings its own, and an agent missing from the PATH is for the launcher to explain.
            if let file = chosen?.unusableChosenPath, Self.runsOwnCLI(support) {
                launchFailures[id] = "The \(adapter.displayName) executable chosen in Settings, \(file), is missing or can't be run."
                apply(.processExited(code: 127), to: id)
                return
            }
            guard let launcher = chatLauncher(for: adapter, inPATH: path) else { return }
            var configuration = ChatSession.Configuration(
                launcher: launcher,
                workingDirectory: worktree.path.path(percentEncoded: false),
                existingAgentSessionID: session.agentSessionID,
                clientInfo: Self.chatClientInfo
            )
            // Files for @ mentions. Checked at each listing and not here, since git can be
            // installed while the chat is open. Throwing makes the chat walk the folder itself.
            configuration.listFiles = { [weak self, git] folder in
                guard await self?.isGitAvailable == true else { throw CocoaError(.featureUnsupported) }
                return try await git.listFiles(in: folder)
            }
            let chat = ChatSession(configuration: configuration)
            chat.onEvent = { [weak self, weak chat] event in
                // A chat replaced by a restart or a switch may still be finishing a step.
                guard let self, let chat, self.chats[id] === chat else { return }
                self.receive(event, for: id)
            }
            // Stored before it starts, so the tab shows it installing or connecting.
            chats[id] = chat
            // Review comments can go into the composer at once. Waiting for the agent would run
            // into the delivery timeout while a first install downloads.
            deliverPendingReview(to: id)
            await chat.start()
        }
    }

    /// The launcher Settings uses to show and update an agent's chat adapter, outside any session.
    /// Nil for an agent without chat, and in previews, which have no registry.
    func chatLauncher(for adapter: any AgentAdapter) async -> ChatLauncher? {
        chatLauncher(for: adapter, inPATH: await loginPATH.value)
    }

    /// Synchronous once the PATH is known, so `launchChat` can build it without a suspension
    /// between its staleness checks and storing the chat.
    private func chatLauncher(for adapter: any AgentAdapter, inPATH path: String) -> ChatLauncher? {
        guard let sources = chatAgents, let support = adapter.acp else { return nil }
        let chosen = settings.executablePath(for: adapter.id).map { Self.locateExecutable(adapter, override: $0, inPATH: path) }
        let cliPath = chosen?.path ?? LoginEnvironment.locate(adapter.executableName, inPATH: path)
        return ChatLauncher(
            agentName: adapter.displayName,
            support: support,
            cliPath: cliPath.map { URL(fileURLWithPath: $0) },
            loginPATH: path,
            locate: { name in LoginEnvironment.locate(name, inPATH: path).map { URL(fileURLWithPath: $0) } },
            registry: sources.registry,
            installer: sources.installer
        )
    }

    private static func runsOwnCLI(_ support: ACPSupport) -> Bool {
        switch support.launch {
        case .cli: true
        case .registry(let cliExecutableVariable): cliExecutableVariable != nil
        }
    }

    private func receive(_ event: ChatSession.Event, for id: Session.ID) {
        guard let session = workspace.session(id: id) else { return }
        switch event {
        case .agent(let event):
            if event == .sessionStarted, activities[id]?.needsUser == true {
                // Starting after a sign-in is what answers it, and `apply` would leave a request
                // in place when the session starts.
                resolveAttention(of: id, to: .finished)
            } else {
                apply(event, to: id)
            }
            // The chat's agent writes the same logs as the CLI.
            if case .turnFinished = event, session.agent.adapter.capabilities.usage == .codexLogs { refreshCodexUsage() }

        case .agentSessionIDConfirmed(let agentSessionID):
            guard session.agentSessionID != agentSessionID else { return }
            mutate { $0.updateSession(id: id) { $0.agentSessionID = agentSessionID } }

        case .titleChanged(let title):
            // Kept apart from the user's own title, which `displayTitle` puts first.
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, session.agentTitle != title else { return }
            mutate { $0.updateSession(id: id) { $0.agentTitle = title } }

        case .usageChanged(let used, let size):
            guard size > 0 else { return }
            let percent = Double(used) / Double(size) * 100
            // No transcript path: the prompt cache countdown reads Claude's terminal transcript,
            // and a chat has no status line that would name it.
            recordContext(
                SessionContext(usedTokens: max(used, 0), windowSize: size, usedPercent: min(max(percent, 0), 100), transcriptPath: nil, model: nil),
                for: id
            )

        case .failed(let failure):
            if case .signInRequired = failure.reason {
                apply(.attentionRequested(.question, message: failure.title), to: id)
            } else {
                // The chat shows what went wrong and offers to try again. Exited would refuse the
                // events of that retry, and starting would spin in the sidebar for good.
                resolveAttention(of: id, to: .notStarted)
            }
        }
    }

    // MARK: Stopping

    /// How long a restart or a switch waits for the old chat's agent to exit before it stops it.
    static let chatStopLimit: Duration = .seconds(2)

    /// Shuts a chat down that is being replaced. A restart or a switch opens the same conversation
    /// again, through `session/load` or `claude --resume`, and two agents must not work on one
    /// conversation at once, so the new launch waits for this; see `waitForStoppingChat(of:)`.
    /// The chat cancels its turn first and its agent gets `chatStopLimit` to exit, so the wait
    /// stays short.
    func stopReplacedChat(_ chat: ChatSession, of id: Session.ID) {
        stoppingChats[id] = Task { await chat.shutDown(exitWithin: Self.chatStopLimit) }
    }

    /// Returns once the chat a restart or a switch replaced has stopped. Callers check again that
    /// their launch is still wanted afterwards: the session may have been closed or switched again.
    func waitForStoppingChat(of id: Session.ID) async {
        guard let stopping = stoppingChats[id] else { return }
        await stopping.value
        if stoppingChats[id] == stopping { stoppingChats[id] = nil }
    }

    // MARK: Terminal or chat

    /// What a plain New Session of `agent` opens as. The "in Chat" and "in Terminal" items offer
    /// the other one.
    func defaultInterface(for agent: any AgentAdapter) -> SessionInterface {
        .forNewSession(of: agent, preferred: settings.interface(for: agent.id), usesPreset: false)
    }

    /// Whether the session may move between terminal and chat. Presets and scripts are terminal
    /// only, and an agent that keeps separate conversations in each could not carry this one over.
    /// The other side also needs its engine: without Ghostty there is no terminal to switch to.
    func canSwitchInterface(_ id: Session.ID) -> Bool {
        guard let session = workspace.session(id: id), let support = session.agent.adapter.acp,
              session.script == nil, scriptSessions[id] == nil, session.arguments == nil,
              session.effectiveInterface == .acp ? hasTerminalEngine : chatAgents != nil
        else { return false }
        return support.sharesConversationIDs || session.agentSessionID == nil
    }

    /// Switches, asking first when that would stop a turn.
    func requestInterfaceSwitch(_ interface: SessionInterface, for id: Session.ID) {
        guard canSwitchInterface(id), workspace.session(id: id)?.effectiveInterface != interface else { return }
        if let interruption = interruption(of: id, by: .switchInterface(to: interface)) {
            sessionAwaitingInterruptDecision = interruption
            return
        }
        setInterface(interface, for: id)
    }

    /// Restarts the session as `interface`. The agent's session id stays, so the terminal resumes
    /// the conversation through the adapter's resume command and the chat loads it. An agent whose
    /// id the app presets (Claude, OpenCode) has none saved until a first turn has proved the
    /// conversation exists, and then the other side starts a new one.
    func setInterface(_ interface: SessionInterface, for id: Session.ID) {
        guard canSwitchInterface(id), workspace.session(id: id)?.effectiveInterface != interface else { return }
        tearDown(id, restarting: true)
        mutate { $0.updateSession(id: id) { $0.interface = interface } }
        ensureRunning(id)
    }

    // MARK: Links

    /// A link in a chat reply. Agent output is untrusted, and stricter rules than the terminal's
    /// apply, because Markdown hides where a link really goes: folders, apps and anything that
    /// runs are only shown in Finder, never opened. Option flips where a file or web page opens,
    /// like ⌘⌥-click in a terminal.
    func openChatLink(_ url: URL, from sessionID: Session.ID) {
        let alternate = NSEvent.modifierFlags.contains(.option)
        switch ChatLinkPolicy.destination(for: url) {
        case .web(let url): openSessionLink(.web(url), alternate: alternate, from: sessionID)
        case .mail(let url): openSessionLink(.mail(url), alternate: alternate, from: sessionID)
        case .file(let url): openSessionLink(.file(url, position: nil), alternate: alternate, from: sessionID)
        case .reveal(let url): NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil: break
        }
    }
}

extension ChatSession {
    /// What the sidebar peek and the tab switcher show of a chat in place of a terminal's last lines:
    /// the agent's last reply, or what the chat is busy with or stuck on. Nil for a chat with
    /// nothing said yet.
    var previewText: String? {
        switch phase {
        case .starting(let step):
            switch step {
            case .preparing, .connecting: "Starting \(agentName)…"
            case .installing(let name, _): "Installing \(name)…"
            case .restoringHistory: "Restoring the conversation…"
            case .signingIn: "Signing in to \(agentName)…"
            }
        case .failed(let failure):
            failure.title
        case .ready:
            lastAgentText
        case .ended(let ending):
            lastAgentText ?? ending.message
        }
    }
}

extension SessionInterface {
    /// The word the user sees. "ACP" stays out of the interface.
    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .acp: "Chat"
        }
    }

    var symbolName: String {
        switch self {
        case .terminal: "terminal"
        case .acp: "bubble.left.and.text.bubble.right"
        }
    }

    var other: SessionInterface {
        switch self {
        case .terminal: .acp
        case .acp: .terminal
        }
    }
}
