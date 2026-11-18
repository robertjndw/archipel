import AgentKit
import ArchipelCore
import SwiftUI

/// Pending "Custom Arguments…" launch, shown as an alert by RootView.
struct CustomArgumentsRequest: Identifiable {
    let id = UUID()
    var worktree: Worktree.ID
    var agentID: String
    var pane: Pane.ID?
}

extension View {
    func customArgumentsAlert(_ request: Binding<CustomArgumentsRequest?>) -> some View {
        modifier(CustomArgumentsAlert(request: request))
    }
}

private struct CustomArgumentsAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: CustomArgumentsRequest?

    func body(content: Content) -> some View {
        content.alert(title, item: $request) { request in
            CustomArgumentsFields(initial: model.settings.agentArguments[request.agentID] ?? "") { text in
                guard let agent = AgentDefinition.builtIn(id: request.agentID) else { return }
                model.newSession(in: request.worktree, agent: agent, arguments: text, pane: request.pane)
            }
        } message: { _ in
            Text("These replace your default extra arguments for this session only.")
        }
    }

    private var title: String {
        let agent = request.flatMap { AgentDefinition.builtIn(id: $0.agentID) }?.displayName ?? "Agent"
        return "New \(agent) Session"
    }
}

private struct CustomArgumentsFields: View {
    let initial: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField("Arguments", text: $text, prompt: Text("--model opus --permission-mode plan"))
            .onAppear { text = initial }
        // Empty is allowed and means no extra arguments.
        Button("Start") { commit(text) }
        Button("Cancel", role: .cancel) {}
    }
}

/// "New … Session With" submenu when the agent has model choices, a single "with Arguments…"
/// item otherwise. Hidden for the shell.
struct NewSessionWithMenu: View {
    let model: AppModel
    let agent: AgentDefinition
    let worktree: Worktree.ID?
    var pane: Pane.ID?

    var body: some View {
        if agent.acceptsPrompts {
            Group {
                if agent.modelChoices.isEmpty {
                    Button("New \(agent.displayName) Session with Arguments…", systemImage: "slider.horizontal.3") { askForArguments() }
                } else {
                    Menu("New \(agent.displayName) Session With", systemImage: "slider.horizontal.3") {
                        ForEach(agent.modelChoices, id: \.self) { choice in
                            Button(AppModel.modelTitle(choice, agent: agent)) {
                                if let worktree { model.newSession(in: worktree, agent: agent, model: choice, pane: pane) }
                            }
                        }
                        Divider()
                        Button("Custom Arguments…") { askForArguments() }
                    }
                }
            }
            .disabled(worktree == nil || !model.canStartSession(with: agent))
        }
    }

    private func askForArguments() {
        guard let worktree, model.readyForSheet() else { return }
        model.customArgumentsRequest = CustomArgumentsRequest(worktree: worktree, agentID: agent.id, pane: pane)
    }
}
