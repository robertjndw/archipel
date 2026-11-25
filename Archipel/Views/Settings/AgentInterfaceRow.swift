import ACPKit
import AgentKit
import ArchipelCore
import ChatUI
import SwiftUI

/// Whether a new session of the agent opens in a terminal or as a chat, and the program the chat
/// runs on. Only for agents that can run as a chat.
struct AgentInterfaceSection: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter

    var body: some View {
        Section {
            // fixedSize only on the control, as in Appearance, so the row still spans the form.
            LabeledContent {
                Picker("New sessions open in", selection: interface) {
                    ForEach(SessionInterface.allCases, id: \.self) { interface in
                        Text(interface.title).tag(interface)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("settings.agents.\(agent.id).interface")
            } label: {
                Text("New sessions open in")
            }
            if case .registry = agent.acp?.launch {
                ChatAdapterRow(agent: agent)
            }
        } footer: {
            Text("Chat shows the conversation as messages instead of a terminal, and talks to the agent over the Agent Client Protocol. Presets always open in a terminal. A session can switch later from the Tab menu.")
        }
    }

    private var interface: Binding<SessionInterface> {
        Binding(
            get: { model.settings.interface(for: agent.id) },
            set: { model.settings.setInterface($0, for: agent.id) }
        )
    }
}

/// The adapter program a chat of this agent runs, downloaded from the ACP registry. A chat installs
/// it on first start by itself; this row shows which version is there and installs or updates it
/// ahead of time, so the user does not wait in the chat.
///
/// Everything here talks to the network or npm, so it runs in one task the row owns: a second click
/// finds it busy, and leaving the pane cancels it.
private struct ChatAdapterRow: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter

    @State private var launcher: ChatLauncher?
    @State private var isLoaded = false
    @State private var installedVersion: String?
    /// A downloaded adapter the registry gave no checksum for, so nothing confirmed it is the
    /// file the registry meant.
    @State private var isUnverified = false
    /// The last answer from the registry, nil until the user checks or installs.
    @State private var latest: ChatAgentUpdateCheck?
    /// The adapter is an npm package and Node.js is not on the login PATH, so installing would only fail.
    @State private var needsNode = false
    @State private var work: Task<Void, Never>?
    @State private var progress: ChatLauncher.Progress?
    @State private var failure: String?

    var body: some View {
        LabeledContent {
            if !needsNode {
                Button(actionTitle, action: primaryAction)
                    .disabled(!isLoaded || launcher == nil || work != nil)
                    .accessibilityIdentifier("settings.agents.\(agent.id).chatAdapter.update")
            }
        } label: {
            Text("Chat support")
            Text(status)
            if isUnverified {
                Text("Not verified: the download came without a checksum.")
            }
            if let failure {
                Text(failure)
            }
        }
        .accessibilityIdentifier("settings.agents.\(agent.id).chatAdapter")
        .task { await load() }
        .onDisappear { work?.cancel() }
    }

    private var status: String {
        if let progress {
            return switch progress {
            case .checkingRegistry: "Checking…"
            case .downloading(let fraction): "Downloading… \(fraction.formatted(.percent.precision(.fractionLength(0))))"
            // Done is only seen for a moment between the install and the row taking it in.
            case .installingPackages, .done: "Installing…"
            }
        }
        if !isLoaded { return "Checking…" }
        if needsNode { return ChatLaunchError.nodeMissing(agentName: agent.displayName).localizedDescription }
        guard let installedVersion else { return "Not installed. Downloaded the first time a chat starts." }
        if let latest, !latest.isUpdateAvailable { return "Version \(installedVersion), up to date" }
        return "Version \(installedVersion)"
    }

    private var actionTitle: String {
        if installedVersion == nil { return "Install Now" }
        if let latest, latest.isUpdateAvailable { return "Update to \(latest.latestVersion)" }
        return "Check for Update"
    }

    private func primaryAction() {
        if installedVersion == nil || latest?.isUpdateAvailable == true {
            perform { launcher, report in
                let version = try await launcher.update(progress: report)
                installedVersion = version ?? installedVersion
                latest = version.map { ChatAgentUpdateCheck(installedVersion: $0, latestVersion: $0) }
                isUnverified = await launcher.installedAdapter()?.isUnverifiedDownload == true
            }
        } else {
            perform { launcher, report in
                // The check reports no progress of its own.
                report(.checkingRegistry)
                let check = try await launcher.checkForUpdate()
                latest = check
                installedVersion = check?.installedVersion ?? installedVersion
            }
        }
    }

    private func load() async {
        guard let launcher = await model.chatLauncher(for: agent) else {
            isLoaded = true
            return
        }
        self.launcher = launcher
        let installed = await launcher.installedAdapter()
        installedVersion = installed?.version
        isUnverified = installed?.isUnverifiedDownload == true
        needsNode = await Self.needsNode(launcher)
        isLoaded = true
    }

    /// Read from the registry copy on disk, so the row can say so before anything is downloaded.
    private static func needsNode(_ launcher: ChatLauncher) async -> Bool {
        let entry = await launcher.registry.offlineIndex().index.agent(id: launcher.support.registryID)
        guard case .npx? = entry?.distribution(for: launcher.platform) else { return false }
        return launcher.locate("node") == nil || launcher.locate("npm") == nil
    }

    /// Progress goes through a stream rather than straight into the state: the launcher reports from
    /// whatever thread it is on, and hopping each report over separately could land a late
    /// "Downloading" after the row has already finished.
    private func perform(
        _ operation: @escaping @MainActor (ChatLauncher, @escaping @Sendable (ChatLauncher.Progress) -> Void) async throws -> Void
    ) {
        guard work == nil, let launcher else { return }
        failure = nil
        let (updates, continuation) = AsyncStream.makeStream(of: ChatLauncher.Progress.self, bufferingPolicy: .bufferingNewest(1))
        work = Task {
            let watcher = Task {
                for await step in updates { progress = step }
            }
            do {
                try await operation(launcher) { continuation.yield($0) }
            } catch {
                // Leaving the pane cancels the work, which is not worth an error on the way out.
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            continuation.finish()
            await watcher.value
            progress = nil
            work = nil
        }
    }
}

#if DEBUG
#Preview("Claude Code") {
    Form {
        AgentInterfaceSection(agent: ClaudeAdapter())
    }
    .formStyle(.grouped)
    .environment(AppModel.preview())
    .frame(width: 500, height: 260)
}

#Preview("OpenCode, Chat by default") {
    let model = AppModel.preview()
    model.settings.setInterface(.acp, for: OpenCodeAdapter().id)
    return Form {
        AgentInterfaceSection(agent: OpenCodeAdapter())
    }
    .formStyle(.grouped)
    .environment(model)
    .frame(width: 500, height: 200)
}
#endif
