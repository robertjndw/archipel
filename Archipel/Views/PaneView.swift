import AgentKit
import ArchipelCore
import EditorUI
import SwiftUI
import TerminalKit

/// The content area of the selected worktree: its panes next to each other.
struct WorktreeContentView: View {
    @Environment(AppModel.self) private var model
    let isSidebarCollapsed: Bool
    let toggleSidebar: () -> Void

    var body: some View {
        if let worktree = model.selectedWorktree {
            HSplitView {
                ForEach(worktree.panes) { pane in
                    PaneView(
                        worktree: worktree,
                        pane: pane,
                        isFocused: pane.id == worktree.focusedPane?.id,
                        showsSidebarToggle: isSidebarCollapsed && pane.id == worktree.panes.first?.id,
                        toggleSidebar: toggleSidebar
                    )
                    .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(.container, edges: .top)
                    .snapsSplitDividerToCenter(enabled: pane.id == worktree.panes.first?.id)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        } else {
            ContentUnavailableView(
                "Nothing Selected",
                systemImage: "sidebar.left",
                description: Text("Choose a worktree in the sidebar, or add a project to this island.")
            )
            // ContentUnavailableView only takes its ideal height, so without this the status bar
            // ends up halfway up the window.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct PaneView: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree
    let pane: Pane
    let isFocused: Bool
    let showsSidebarToggle: Bool
    let toggleSidebar: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneTabBar(
                worktree: worktree,
                pane: pane,
                isFocused: isFocused,
                showsSidebarToggle: showsSidebarToggle,
                toggleSidebar: toggleSidebar
            )
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            model.paneFrames[pane.id] = frame
        }
        .onDisappear { model.paneFrames[pane.id] = nil }
    }

    @ViewBuilder
    private var content: some View {
        switch pane.selectedTab?.content {
        case .session(let id):
            SessionContent(sessionID: id)
        case .file(let url):
            FileEditor(url: url, store: model.documents)
        case .diff(let path, let staged):
            DiffViewer(
                root: worktree.path,
                path: path,
                staged: staged,
                comments: model.reviewComments,
                targets: model.reviewTargets(in: worktree),
                onSend: { model.sendReviewComments(in: worktree.id, to: $0) }
            )
        case nil:
            ContentUnavailableView {
                Label("No Tabs", systemImage: "terminal")
            } description: {
                Text("Start an agent or a shell in \(worktree.displayName), or open a file from the sidebar on the right.")
            } actions: {
                GlassEffectContainer {
                    HStack(spacing: 8) {
                        ForEach(AgentDefinition.builtIns) { agent in
                            Button(agent.displayName, systemImage: agent.symbolName) {
                                model.newSession(in: worktree.id, agent: agent, pane: pane.id)
                            }
                        }
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        }
    }
}

private struct SessionContent: View {
    @Environment(AppModel.self) private var model
    let sessionID: Session.ID

    var body: some View {
        let activity = model.activity(for: sessionID)
        Group {
            if let terminal = model.terminals[sessionID] {
                TerminalView(session: terminal)
                    // A new identity per session, so SwiftUI swaps the hosted
                    // terminal view instead of reusing one representable.
                    .id(sessionID)
            } else if let failure = model.launchFailures[sessionID] {
                ContentUnavailableView {
                    Label("Could Not Start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { model.restartSession(sessionID) }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if case .exited(let code) = activity.status, model.terminals[sessionID] != nil {
                ExitedBar(code: code) { model.restartSession(sessionID) }
            }
        }
    }
}

/// Sits below the terminal rather than over it, so the last lines of output
/// stay readable.
private struct ExitedBar: View {
    let code: Int32
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(
                code == 0 ? "This session has ended." : "This session exited with code \(code).",
                systemImage: code == 0 ? "stop.circle" : "exclamationmark.triangle"
            )
            .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Restart", systemImage: "arrow.clockwise", action: restart)
                .buttonStyle(.glassProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.windowBackground)
        .overlay(alignment: .top) { Divider() }
    }
}
