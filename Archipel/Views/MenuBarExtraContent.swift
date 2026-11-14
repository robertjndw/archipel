import AgentKit
import ArchipelCore
import SwiftUI

/// What the menu bar panel lists, in the order it lists it: sessions that need the user, then
/// working ones, then finished ones nobody has looked at yet.
struct MenuBarEntry: Identifiable, Equatable {
    enum Kind: Int { case needsYou, working, unread }

    let id: Session.ID
    let kind: Kind
    let agentName: String
    let symbol: String
    let location: String
    let detail: String
}

extension AppModel {
    var menuBarEntries: [MenuBarEntry] {
        var entries: [MenuBarEntry] = []
        for project in workspace.islands.flatMap(\.projects) {
            for worktree in project.worktrees {
                for session in worktree.sessions {
                    guard let activity = activities[session.id], let kind = Self.menuBarKind(of: activity) else { continue }
                    let definition = session.agent.definition
                    let branch = worktree.branch ?? worktree.path.lastPathComponent
                    entries.append(MenuBarEntry(
                        id: session.id,
                        kind: kind,
                        agentName: definition.displayName,
                        symbol: definition.symbolName,
                        location: "\(project.name) / \(branch)",
                        detail: Self.menuBarDetail(of: activity)
                    ))
                }
            }
        }
        // Offsets break ties so each group keeps sidebar order.
        return entries.enumerated()
            .sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }
            .map(\.element)
    }

    private static func menuBarKind(of activity: SessionActivity) -> MenuBarEntry.Kind? {
        if activity.needsUser { return .needsYou }
        switch activity.status {
        case .working, .starting: return .working
        case .finished where activity.unread: return .unread
        default: return nil
        }
    }

    private static func menuBarDetail(of activity: SessionActivity) -> String {
        switch activity.status {
        case .needsAttention(.permission): "Needs your approval"
        case .needsAttention(.question): "Asked you a question"
        case .needsAttention(.idle): "Waiting for you"
        case .working, .starting: "Working"
        default: "Finished"
        }
    }
}

/// The menu bar glyph. Colour is not guaranteed in the menu bar, so the attention state also
/// changes the symbol.
struct MenuBarExtraLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let summary = attentionSummary(of: model.workspace, activities: model.activities)
        let description = summary.accessibilityDescription
        if summary.needsAttention > 0 {
            Image(systemName: "mountain.2.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.orange, .orange)
                .accessibilityLabel("Archipel, \(description)")
        } else {
            Image(systemName: "mountain.2")
                .symbolEffect(.pulse, isActive: summary.working > 0)
                .accessibilityLabel(description.isEmpty ? "Archipel" : "Archipel, \(description)")
        }
    }
}

struct MenuBarExtraContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let entries = model.menuBarEntries
        VStack(alignment: .leading, spacing: 2) {
            if entries.isEmpty {
                Text("No sessions need you")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    MenuBarRow(entry: entry) { show(entry.id) }
                }
            }
            Divider().padding(.vertical, 4)
            MenuBarButton(title: "Open Archipel", systemImage: "macwindow") { showMainWindow() }
            MenuBarButton(title: "Quit Archipel", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func showMainWindow() {
        NSApp.activate()
        // Does nothing visible while the window is open; brings it back after the user closed it.
        openWindow(id: "main")
    }

    private func show(_ id: Session.ID) {
        showMainWindow()
        model.select(session: id)
    }
}

private struct MenuBarRow: View {
    let entry: MenuBarEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: entry.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.agentName)
                        .lineLimit(1)
                    Text(entry.location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(entry.detail)
                    .font(.caption)
                    .foregroundStyle(entry.kind == .needsYou ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .contentShape(.rect)
        }
        .buttonStyle(MenuBarRowStyle())
    }
}

private struct MenuBarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .buttonStyle(MenuBarRowStyle())
    }
}

private struct MenuBarRowStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                in: .rect(cornerRadius: 6)
            )
            .onHover { isHovering = $0 }
    }
}
