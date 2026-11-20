import AgentKit
import SwiftUI

struct AgentSettingsView: View {
    @Environment(AppModel.self) private var model
    private let agents = AgentDefinition.builtIns.filter { $0.id != AgentDefinition.shell.id }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Picker(selection: $settings.defaultAgentID) {
                    ForEach(AgentDefinition.builtIns) { agent in
                        // Still selectable: the agent may be installed later, and its section below
                        // says where it was looked for.
                        Label(
                            model.isInstalled(agent) ? agent.displayName : "\(agent.displayName) (Not Installed)",
                            symbol: agent.symbolName
                        )
                        .tag(agent.id)
                    }
                } label: {
                    Text("Default agent")
                    Text("Started by New Session (⌘T) and the plus button.")
                }
            }

            ForEach(agents) { agent in
                AgentSection(agent: agent, showsFooter: agent.id == agents.last?.id)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSection: View {
    @Environment(AppModel.self) private var model
    let agent: AgentDefinition
    /// The arguments note is the same for every agent, so only the last section shows it.
    let showsFooter: Bool
    /// Nil while the login PATH is still being resolved.
    @State private var location: String??

    var body: some View {
        Section {
            LabeledContent("Executable") {
                switch location {
                case .none:
                    ProgressView().controlSize(.small)
                case .some(.some(let path)):
                    Label {
                        Text(URL(filePath: path).abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    .foregroundStyle(.secondary)
                    .help(path)
                case .some(.none):
                    Label {
                        Text("\(agent.executableName) not found on your PATH")
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            if agent.acceptsPrompts {
                PresetsEditor(agent: agent)
            }
        } header: {
            Label(agent.displayName, symbol: agent.symbolName)
        } footer: {
            if showsFooter {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Session (⌘T) uses the agent's default preset, or no extra arguments if it has none. Quote values that contain spaces.")
                    Text("All presets show up under File > New Session with Preset, and the first nine get ⌃⌘1 to ⌃⌘9. A session started from one keeps its arguments even if you edit the preset later.")
                }
            }
        }
        .task {
            let path = await model.toolSearchPATH()
            location = .some(LoginEnvironment.locate(agent.executableName, inPATH: path))
        }
    }

}

/// One agent's slice of `AppSettings.launchPresets`, edited in place like the lists in System
/// Settings. The settings keep every agent's presets in one array, so edits go through the ids.
private struct PresetsEditor: View {
    @Environment(AppModel.self) private var model
    let agent: AgentDefinition
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
        agent.id == AgentDefinition.claude.id ? "--model opus" : "--model gpt-5"
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
        // The size the Settings window gives each pane.
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("No presets") {
    let model = AppModel.preview()
    model.settings.launchPresets = []
    return AgentSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}

#Preview("Presets") {
    let model = AppModel.preview()
    let plan = LaunchPreset(agentID: AgentDefinition.claude.id, name: "Plan", arguments: "--model opus --permission-mode plan")
    let mini = LaunchPreset(agentID: AgentDefinition.codex.id, name: "Mini", arguments: "--model gpt-5-mini")
    model.settings.launchPresets = LaunchPreset.defaults + [plan, mini]
    model.settings.setDefaultPreset(plan.id, for: AgentDefinition.claude.id)
    return AgentSettingsView()
        .environment(model)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 540)
}
#endif
