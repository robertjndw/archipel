import AgentKit
import ArchipelCore
import SwiftUI

/// Pending "Custom…" model pick, shown as an alert by RootView.
struct CustomModelRequest: Identifiable {
    let id = UUID()
    var worktree: Worktree.ID
    var agentID: String
    var pane: Pane.ID?
}

extension View {
    func customModelAlert(_ request: Binding<CustomModelRequest?>) -> some View {
        modifier(CustomModelAlert(request: request))
    }
}

private struct CustomModelAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var request: CustomModelRequest?

    func body(content: Content) -> some View {
        content.alert("New Session with Model", item: $request) { request in
            CustomModelFields { name in
                guard let agent = AgentDefinition.builtIn(id: request.agentID) else { return }
                model.newSession(in: request.worktree, agent: agent, model: name, pane: request.pane)
            }
        } message: { request in
            let agent = AgentDefinition.builtIn(id: request.agentID)?.displayName ?? "the agent"
            Text("Only this \(agent) session uses the model. Your default arguments don't change.")
        }
    }
}

private struct CustomModelFields: View {
    let commit: (String) -> Void
    @State private var name = ""

    var body: some View {
        TextField("Model", text: $name, prompt: Text("claude-opus-5-5"))
        Button("Start") {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { commit(trimmed) }
        }
        Button("Cancel", role: .cancel) {}
    }
}

/// "New Claude Code Session With" submenu. Hidden for agents without model choices.
struct NewSessionWithModelMenu: View {
    let model: AppModel
    let agent: AgentDefinition
    let worktree: Worktree.ID?
    var pane: Pane.ID?

    var body: some View {
        if !agent.modelChoices.isEmpty {
            Menu("New \(agent.displayName) Session With", systemImage: "cpu") {
                ForEach(agent.modelChoices, id: \.self) { choice in
                    Button(AppModel.modelTitle(choice, agent: agent)) {
                        if let worktree { model.newSession(in: worktree, agent: agent, model: choice, pane: pane) }
                    }
                }
                Divider()
                Button("Custom…") {
                    guard let worktree, model.readyForSheet() else { return }
                    model.customModelRequest = CustomModelRequest(worktree: worktree, agentID: agent.id, pane: pane)
                }
            }
            .disabled(worktree == nil || !model.canStartSession(with: agent))
        }
    }
}
