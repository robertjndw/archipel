import AgentKit
import AppKit
import SwiftUI

/// The agents in a list on the left, grouped into on and off, and the selected one's settings on
/// the right. Wider than the other panes, since it is two columns.
struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("settings.selectedAgent") private var storedSelection = ""

    var body: some View {
        HStack(spacing: 0) {
            // No divider: the toolbar above has no separator for a line to meet, and the cards
            // on the right already set the detail apart from the list.
            AgentList(selection: selection)
                .frame(width: 210)
            if let agent = selectedAgent {
                AgentDetails(agent: agent)
                    // A fresh form per agent, so the scroll position and the presets table's
                    // selection don't carry over to the next one.
                    .id(agent.id)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// The stored id can name an agent that no longer exists, or nothing yet. The default agent
    /// is the one worth showing first then.
    private var selectedAgent: (any AgentAdapter)? {
        model.agentRegistry.adapter(id: storedSelection) ?? model.defaultAgent
    }

    private var selection: Binding<String?> {
        Binding(
            get: { selectedAgent?.id },
            // The list clears its selection on a click into empty space. Keep the agent shown.
            set: { id in if let id { storedSelection = id } }
        )
    }
}

/// How the list groups the agents. A missing executable is not a group of its own: the agent is
/// still on, and its row and details say what is wrong.
private enum AgentGroup: CaseIterable {
    case on, off

    var title: String {
        switch self {
        case .on: "On"
        case .off: "Off"
        }
    }
}

/// The list never becomes first responder, so its selection stays the quiet gray of an inactive
/// list instead of the accent fill, the way the reference sidebars look. It is still a real List
/// selection for VoiceOver; the arrow keys go through the focusable wrapper instead.
private struct AgentList: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.group) { group in
                Section {
                    ForEach(group.agents, id: \.id) { agent in
                        AgentListRow(agent: agent)
                            .tag(agent.id)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.group.title)
                        Spacer()
                        Text(group.agents.count, format: .number)
                            .monospacedDigit()
                    }
                    // A sidebar list lays its headers out wider than its rows, by the selection's
                    // inset. Taking that back ends the count where the rows' dots end.
                    .padding(.trailing, AgentListRow.trailingInset + 12)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .listStyle(.sidebar)
        // One surface for the whole window: the list sits on the pane's background, not its own.
        .scrollContentBackground(.hidden)
        .focusable(false)
        .accessibilityIdentifier("settings.agents.list")
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand(perform: move)
        // A click selects through the table, which can't take focus, so the keys follow it here.
        .onChange(of: selection) { isFocused = true }
    }

    /// Only the groups that have agents, in the order the list shows them.
    private var groups: [(group: AgentGroup, agents: [any AgentAdapter])] {
        AgentGroup.allCases.compactMap { group in
            let agents = model.agentRegistry.adapters.filter {
                model.settings.isEnabled($0.id) == (group == .on)
            }
            return agents.isEmpty ? nil : (group, agents)
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        let ids = groups.flatMap { $0.agents.map(\.id) }
        guard let current = selection.flatMap(ids.firstIndex(of:)) else { return }
        switch direction {
        case .up where current > ids.startIndex: selection = ids[current - 1]
        case .down where current < ids.endIndex - 1: selection = ids[current + 1]
        default: break
        }
    }
}

private struct AgentListRow: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter

    /// What the row's content keeps clear of the selection's trailing edge, shared with the
    /// section headers so their counts end where the dots do.
    static let trailingInset: CGFloat = 2

    var body: some View {
        let isEnabled = model.settings.isEnabled(agent.id)
        HStack(spacing: 8) {
            Image(symbol: agent.symbolName)
                .font(.system(size: 15))
                // A fixed, centered frame so the names line up whatever the symbol's width.
                .frame(width: 20, alignment: .center)
                // The logos are multicolor, so only dropping the colour makes an off one gray.
                .saturation(isEnabled ? 1 : 0)
            Text(agent.displayName)
                .lineLimit(1)
            Spacer(minLength: 4)
            if isEnabled {
                Circle()
                    .fill(model.isInstalled(agent) ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                    .padding(.trailing, Self.trailingInset)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .accessibilityElement(children: .combine)
        // The dot is colour only, so VoiceOver hears the status in words.
        .accessibilityValue(!isEnabled ? "Off" : model.isInstalled(agent) ? "On" : "On, not installed")
        .accessibilityIdentifier("settings.agents.\(agent.id).row")
    }
}

/// Everything about one agent: a card with its switch, executable and default, then its presets
/// and whatever its adapter asks for. An agent that is off keeps all of it editable, so its
/// presets can be set up before it is turned on.
private struct AgentDetails: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter

    var body: some View {
        Form {
            Section {
                header
                ExecutableRow(agent: agent)
                LabeledContent("Default") {
                    if isDefault {
                        Text("Default agent")
                            .foregroundStyle(.secondary)
                    } else {
                        // makeDefault turns an agent that is off back on.
                        Button("Make Default") { model.makeDefault(agent) }
                            .accessibilityIdentifier("settings.agents.\(agent.id).makeDefault")
                    }
                }
            } footer: {
                Text(isEnabled
                    ? "New Session (⌘T) and the plus button start the default agent."
                    : "Agents that are off leave the New Session menus. Sessions already open keep running.")
            }

            if agent.capabilities.acceptsPrompts {
                Section {
                    PresetsEditor(agent: agent)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("New Session (⌘T) uses the agent's default preset, or no extra arguments if it has none. Quote values that contain spaces.")
                        Text("All presets show up under File > New Session with Preset, and the first nine get ⌃⌘1 to ⌃⌘9. A session started from one keeps its arguments even if you edit the preset later.")
                    }
                }
            }

            ForEach(agent.capabilities.settingsSections, id: \.self) { section in
                settingsSection(section)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var isEnabled: Bool { model.settings.isEnabled(agent.id) }
    private var isDefault: Bool { isEnabled && model.defaultAgent.id == agent.id }

    private var header: some View {
        HStack(spacing: 12) {
            Image(symbol: agent.symbolName)
                .font(.system(size: 28))
                // Barely wider than the symbol, so it lines up with the row labels below it.
                .frame(width: 30)
                .saturation(isEnabled ? 1 : 0)
                .foregroundStyle(isEnabled ? .primary : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.title3.weight(.semibold))
                Text(statusLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            Toggle("Show \(agent.displayName) in New Session menus", isOn: enabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!model.canDisable(agent))
                .help(model.canDisable(agent) ? "" : "At least one agent stays in the New Session menus.")
                .accessibilityIdentifier("settings.agents.\(agent.id).enabled")
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        guard isEnabled else { return "Off" }
        var parts = ["On"]
        if isDefault { parts.append("default agent") }
        if !model.isInstalled(agent) { parts.append("not installed") }
        return parts.joined(separator: " · ")
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.settings.isEnabled(agent.id) },
            set: { model.setEnabled($0, for: agent) }
        )
    }

    @ViewBuilder private func settingsSection(_ section: AgentSettingsSection) -> some View {
        switch section {
        case .claudeShellHooks:
            Section {
                ShellHooksRows(controller: model.claudeUserHooks)
            } footer: {
                Text("Gives a Claude you start in a shell tab the same status as one Archipel starts. Adds hooks to your Claude settings.json that only run inside Archipel and leaves your other settings alone. Applies to Claude started after you turn this on.")
            }
        case .codexHooksStatus:
            Section { CodexHooksStatusRows() }
        case .openCodeIntegration:
            OpenCodeIntegrationRows()
        }
    }
}

/// Where the agent is started from: found on the login PATH, or a file the user picked because
/// it lives somewhere the PATH does not reach.
private struct ExecutableRow: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter
    /// Nil while the login PATH is still being resolved.
    @State private var location: ExecutableLocation?

    private var chosenPath: String? { model.settings.executablePath(for: agent.id) }

    var body: some View {
        LabeledContent("Executable") {
            HStack(spacing: 8) {
                value
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("settings.agents.\(agent.id).executable")
                Button("Choose…", action: choose)
                if chosenPath != nil {
                    Button("Use PATH") { model.setExecutablePath(nil, for: agent) }
                        .help("Look for \(agent.executableName) on your PATH again")
                }
            }
        }
        .task(id: chosenPath) {
            location = await model.locate(agent)
        }
    }

    @ViewBuilder private var value: some View {
        switch location {
        case nil:
            Text("Looking for \(agent.executableName)…")
                .foregroundStyle(.secondary)
        case .onPATH(let path), .chosen(let path):
            Text(URL(filePath: path).abbreviatedPath)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .help(path)
        case .chosenMissing(let path):
            Text("Chosen file is missing")
                .foregroundStyle(.orange)
                .help(path)
        case .notOnPATH:
            Text("Not found on your PATH")
                .foregroundStyle(.orange)
                .help("Looked for \(agent.executableName) on your login shell's PATH")
        }
    }

    /// An open panel rather than `fileImporter`: agents are usually installed as symlinks into a
    /// versioned folder, and the panel must keep the link, not pin the version it points at today.
    /// Hidden folders are shown since `~/.local/bin` and friends are where they tend to live.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the \(agent.displayName) executable."
        let current = location?.path ?? chosenPath
        panel.directoryURL = current.map { URL(filePath: $0).deletingLastPathComponent() }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            model.setExecutablePath(url.path, for: agent)
        }
    }
}

extension AppModel {
    fileprivate func locate(_ agent: any AgentAdapter) async -> ExecutableLocation {
        let path = await toolSearchPATH()
        return Self.locateExecutable(agent, override: settings.executablePath(for: agent.id), inPATH: path)
    }
}

/// The opt-in switch that makes a Claude typed by hand into a shell tab report to Archipel.
private struct ShellHooksRows: View {
    @Environment(AppModel.self) private var model
    let controller: ClaudeUserHooksController

    var body: some View {
        Toggle(isOn: enabled) {
            Text("Full status in shell tabs")
            if let message = statusMessage {
                Text(message).foregroundStyle(isProblem ? .orange : .secondary)
            }
        }
        // In a grouped form SwiftUI gives the switch no accessible name, so VoiceOver would read it
        // as just "switch".
        .accessibilityLabel("Full status for Claude started in a shell tab")
        .accessibilityIdentifier("settings.claudeUserHooks")
        .task { await controller.reload() }
        if model.settings.claudeUserHooksEnabled, let file = controller.settingsFile {
            LabeledContent("Settings file") {
                HStack(spacing: 8) {
                    Text(file.abbreviatedPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .help(file.path)
                    Button("Reveal") { reveal(file) }
                }
            }
        }
    }

    private var enabled: Binding<Bool> {
        Binding(
            get: { model.settings.claudeUserHooksEnabled },
            set: { on in
                model.settings.claudeUserHooksEnabled = on
                Task { await controller.setEnabled(on) }
            }
        )
    }

    private var isProblem: Bool {
        switch controller.state {
        case .failed, .translocated: true
        case .outdated: model.settings.claudeUserHooksEnabled
        default: false
        }
    }

    /// Problems show even with the switch off, since turning it on is what just failed.
    private var statusMessage: String? {
        switch controller.state {
        case .translocated: return "Move Archipel to the Applications folder, then turn this on."
        case .failed(let message): return message
        default: break
        }
        guard model.settings.claudeUserHooksEnabled else { return nil }
        switch controller.state {
        case .unknown: return "Checking..."
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .outdated: return "Out of date. Updated the next time Archipel starts."
        case .translocated, .failed: return nil
        }
    }

    private func reveal(_ file: URL) {
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(file.deletingLastPathComponent())
        }
    }
}

/// One agent's slice of `AppSettings.launchPresets`, edited in place like the lists in System
/// Settings. The settings keep every agent's presets in one array, so edits go through the ids.
private struct PresetsEditor: View {
    @Environment(AppModel.self) private var model
    let agent: any AgentAdapter
    @State private var selection: Set<LaunchPreset.ID> = []

    private var presets: [LaunchPreset] {
        model.settings.launchPresets.filter { $0.agentID == agent.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets")
            VStack(spacing: 0) {
                Table(of: LaunchPreset.self, selection: $selection) {
                    TableColumn("Name") { preset in
                        HStack(spacing: 6) {
                            TextField("Name", text: binding(preset.id, \.name), prompt: Text("Name"))
                                .labelsHidden()
                            if preset.id == defaultID {
                                Text("Default")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary, in: .capsule)
                                    .fixedSize()
                            }
                        }
                    }
                    .width(min: 80, ideal: 120, max: 200)
                    TableColumn("Arguments") { preset in
                        TextField("Arguments", text: binding(preset.id, \.arguments), prompt: Text(prompt))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .accessibilityIdentifier("settings.presets.\(agent.id).arguments")
                    }
                } rows: {
                    ForEach(presets) { preset in
                        TableRow(preset)
                            .draggable(preset.id.uuidString)
                    }
                    .dropDestination(for: String.self, action: move)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .onDeleteCommand(perform: removeSelection)
                .frame(height: tableHeight)

                Divider()
                HStack(spacing: 0) {
                    Button("Add Preset", systemImage: "plus", action: add)
                        .accessibilityIdentifier("settings.presets.\(agent.id).add")
                    Divider().frame(height: 16)
                    Button("Remove Preset", systemImage: "minus", action: removeSelection)
                        .disabled(selection.isEmpty)
                    Spacer()
                    // Text rather than an icon, the way Terminal labels its own "Default" button.
                    Button(selectionIsDefault ? "Clear Default" : "Set as Default", action: toggleDefault)
                        .labelStyle(.titleOnly)
                        .disabled(selection.count != 1)
                        .padding(.trailing, 4)
                        .accessibilityIdentifier("settings.presets.\(agent.id).toggleDefault")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(height: 22)
                .padding(.horizontal, 4)
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6).strokeBorder(.separator)
            }
        }
    }

    private var prompt: String {
        agent.capabilities.presetPlaceholder
    }

    /// Grows with the rows up to seven so no row is cut in half by the button bar. Past that
    /// the table scrolls.
    private var tableHeight: CGFloat {
        let rowHeight: CGFloat = 24, headerHeight: CGFloat = 28
        return headerHeight + rowHeight * CGFloat(min(max(presets.count, 2), 7)) + 4
    }

    private func binding(_ id: LaunchPreset.ID, _ keyPath: WritableKeyPath<LaunchPreset, String>) -> Binding<String> {
        Binding(
            get: { model.settings.launchPresets.first { $0.id == id }?[keyPath: keyPath] ?? "" },
            set: { value in
                guard let index = model.settings.launchPresets.firstIndex(where: { $0.id == id }) else { return }
                model.settings.launchPresets[index][keyPath: keyPath] = value
            }
        )
    }

    private var defaultID: LaunchPreset.ID? {
        model.settings.defaultPreset(for: agent.id)?.id
    }

    private var selectionIsDefault: Bool {
        selection.count == 1 && selection.first == defaultID
    }

    private func toggleDefault() {
        guard selection.count == 1, let id = selection.first else { return }
        model.settings.setDefaultPreset(selectionIsDefault ? nil : id, for: agent.id)
    }

    private func add() {
        let preset = LaunchPreset(agentID: agent.id, name: "New Preset", arguments: "")
        model.settings.launchPresets.append(preset)
        selection = [preset.id]
    }

    private func removeSelection() {
        model.settings.launchPresets.removeAll { selection.contains($0.id) }
        selection = []
    }

    /// Reorders this agent's presets among the slots they already hold, so the other agents'
    /// presets keep their places in the shared list. Rows travel as their id strings; anything
    /// else dropped on the table matches no row and is ignored.
    private func move(to destination: Int, ids: [String]) {
        var reordered = presets
        let source = IndexSet(reordered.indices.filter { ids.contains(reordered[$0].id.uuidString) })
        guard !source.isEmpty else { return }
        reordered.move(fromOffsets: source, toOffset: destination)
        var next = reordered.makeIterator()
        model.settings.launchPresets = model.settings.launchPresets.map { preset in
            preset.agentID == agent.id ? next.next() ?? preset : preset
        }
    }
}


#if DEBUG
#Preview("Agents") {
    AgentSettingsView()
        .environment(AppModel.preview())
        // The size the Settings window gives this pane.
        .frame(width: 720, height: 540)
}

#Preview("Codex off, OpenCode missing") {
    let model = AppModel.preview()
    model.setEnabled(false, for: CodexAdapter())
    // A chosen file that isn't there, so OpenCode shows as not installed once the lookup ends.
    model.setExecutablePath("/nonexistent/opencode", for: OpenCodeAdapter())
    return AgentSettingsView()
        .environment(model)
        .frame(width: 720, height: 540)
}
#endif
