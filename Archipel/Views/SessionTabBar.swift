import AgentKit
import ArchipelCore
import SwiftUI

/// The sessions of the selected worktree, one tab each.
struct SessionTabBar: View {
    @Environment(AppModel.self) private var model
    let worktree: Worktree
    @State private var renaming: RenameTarget?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(worktree.sessions) { session in
                        SessionTab(
                            session: session,
                            activity: model.activity(for: session.id),
                            isSelected: session.id == model.selectedSessionID,
                            select: { model.select(session: session.id) },
                            close: { model.removeSession(session.id) }
                        )
                        .contextMenu { tabMenu(session) }
                    }
                }
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.hidden)

            Menu {
                NewSessionButtons(worktree: worktree.id)
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 10)
            .help("New session")
            .accessibilityLabel("New session")
        }
        .frame(height: 36)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .renameAlert($renaming)
    }

    @ViewBuilder
    private func tabMenu(_ session: Session) -> some View {
        Button("Rename…", systemImage: "pencil") {
            renaming = RenameTarget(kind: .session(session.id), name: session.displayTitle)
        }
        Divider()
        Button("Restart", systemImage: "arrow.clockwise") { model.restartSession(session.id) }
        if session.agentSessionID != nil {
            Button("Restart with a New Conversation", systemImage: "plus.bubble") {
                model.restartSession(session.id, fresh: true)
            }
        }
        Divider()
        Button("Close Session", systemImage: "xmark", role: .destructive) { model.removeSession(session.id) }
    }
}

private struct SessionTab: View {
    let session: Session
    let activity: SessionActivity
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: AgentDefinition.builtIn(id: session.agent.rawValue)?.symbolName ?? "terminal")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(session.displayTitle)
                .lineLimit(1)
                .fontWeight(activity.unread ? .semibold : .regular)
            // The close button takes the status glyph's place on hover, so
            // tabs do not change width under the pointer.
            ZStack {
                StatusGlyph(activity: activity)
                    .opacity(isHovering ? 0 : 1)
                Button("Close Session", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(minWidth: 110, maxWidth: 240, minHeight: 26)
        .background(isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 7))
        .contentShape(.rect(cornerRadius: 7))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
        .help(session.displayTitle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}
