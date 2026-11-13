import AgentKit
import ArchipelCore
import SwiftUI
import TerminalKit

struct SessionDetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let worktree = model.selectedWorktree {
            let project = model.workspace.project(containingWorktree: worktree.id)
            VStack(spacing: 0) {
                if !worktree.sessions.isEmpty {
                    SessionTabBar(worktree: worktree)
                }
                if let session = model.selectedSession {
                    terminal(for: session)
                } else {
                    ContentUnavailableView {
                        Label("No Sessions", systemImage: "terminal")
                    } description: {
                        Text("Start an agent or a shell in \(worktree.displayName).")
                    } actions: {
                        ForEach(AgentDefinition.builtIns) { agent in
                            Button(agent.displayName, systemImage: agent.symbolName) {
                                model.newSession(in: worktree.id, agent: agent)
                            }
                        }
                    }
                }
            }
            .navigationTitle(project?.name ?? worktree.displayName)
            .navigationSubtitle(worktree.branch ?? "")
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.left",
                description: Text("Choose a worktree in the sidebar, or add a project to this island.")
            )
        }
    }

    @ViewBuilder
    private func terminal(for session: Session) -> some View {
        let activity = model.activity(for: session.id)
        Group {
            if let terminal = model.terminals[session.id] {
                TerminalView(session: terminal)
                    // A new identity per session, so SwiftUI swaps the hosted
                    // terminal view instead of reusing one representable.
                    .id(session.id)
            } else if let failure = model.launchFailures[session.id] {
                ContentUnavailableView {
                    Label("Could Not Start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { model.restartSession(session.id) }
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .exited(let code) = activity.status, model.terminals[session.id] != nil {
                ExitedBar(code: code) { model.restartSession(session.id) }
            }
        }
    }
}

private struct ExitedBar: View {
    let code: Int32
    let restart: () -> Void

    var body: some View {
        HStack {
            Label(
                code == 0 ? "This session has ended." : "This session exited with code \(code).",
                systemImage: code == 0 ? "stop.circle" : "exclamationmark.triangle"
            )
            Spacer()
            Button("Restart", action: restart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
