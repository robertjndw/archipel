import AgentKit
import SwiftUI

struct AgentSettingsView: View {
    private let agents = AgentDefinition.builtIns.filter { $0.id != AgentDefinition.shell.id }

    var body: some View {
        Form {
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
                        Text((path as NSString).abbreviatingWithTildeInPath)
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
            LabeledContent("Extra arguments") {
                TextField(
                    "Extra arguments",
                    text: Binding(
                        get: { model.settings.agentArguments[agent.id] ?? "" },
                        set: { model.settings.agentArguments[agent.id] = $0.isEmpty ? nil : $0 }
                    ),
                    prompt: Text(prompt)
                )
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .font(.body.monospaced())
                .autocorrectionDisabled()
            }
        } header: {
            Label(agent.displayName, systemImage: agent.symbolName)
        } footer: {
            if showsFooter {
                Text("Extra arguments are added to every launch and resume. Quote values that contain spaces. Running sessions keep the arguments they started with.")
            }
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
