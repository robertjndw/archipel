import AgentKit
import SwiftUI

struct AgentSettingsView: View {
    var body: some View {
        Form {
            ForEach(AgentDefinition.builtIns.filter { $0.id != AgentDefinition.shell.id }) { agent in
                AgentArgumentsSection(agent: agent)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentArgumentsSection: View {
    @Environment(AppModel.self) private var model
    let agent: AgentDefinition
    /// Nil while the login PATH is still being resolved.
    @State private var location: String??

    var body: some View {
        Section {
            TextField(
                "Arguments",
                text: Binding(
                    get: { model.settings.agentArguments[agent.id] ?? "" },
                    set: { model.settings.agentArguments[agent.id] = $0.isEmpty ? nil : $0 }
                ),
                prompt: Text(prompt)
            )
            .font(.body.monospaced())
            .autocorrectionDisabled()
            LabeledContent("Executable") {
                switch location {
                case .none: ProgressView().controlSize(.small)
                case .some(.some(let path)): Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                case .some(.none): Label("\(agent.executableName) not found on your PATH", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        } header: {
            Label(agent.displayName, systemImage: agent.symbolName)
        } footer: {
            Text("Appended to every new launch and resume of \(agent.displayName), for example \(prompt). Quote values that contain spaces. Running sessions are not affected.")
        }
        .task {
            let path = await model.toolSearchPATH()
            location = .some(LoginEnvironment.locate(agent.executableName, inPATH: path))
        }
    }

    private var prompt: String {
        agent.id == AgentDefinition.claude.id ? "--model opus" : "--model gpt-5"
    }
}
