import AgentKit
import AppKit
import ArchipelCore
import SwiftUI

/// What the menu bar panel lists, in the order it lists it: sessions that need the user, then
/// working ones, then finished ones nobody has looked at yet.
struct MenuBarEntry: Identifiable, Equatable {
    enum Kind: Int { case needsYou, working, unread }

    let id: Session.ID
    let kind: Kind
    /// What the sidebar and tab bar call the session, so two sessions of one agent can be told apart.
    let title: String
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
                        title: session.displayTitle,
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
        case .working, .starting: "Working"
        default: "Finished"
        }
    }
}

/// The menu bar glyph: the app icon's islands, colored by the most pressing state across all
/// islands. With nothing going on it is a plain template image that the menu bar tints like every
/// other icon; a status bar item only keeps its colors when its image is not a template.
struct MenuBarExtraLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let summary = model.workspaceAttention
        let description = summary.accessibilityDescription
        let isWorking = summary.working > 0 && summary.needsAttention == 0
        HStack(spacing: 3) {
            Image(nsImage: Self.image(for: Self.color(for: summary)))
            if summary.needsAttention > 0 {
                Text(summary.needsAttention, format: .number)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
        }
        .accessibilityLabel(description.isEmpty ? "Archipel" : "Archipel, \(description)")
        .task(id: isWorking && !reduceMotion) {
            await StatusItemBreathing.update(isWorking: isWorking && !reduceMotion)
        }
    }

    /// Same colors as the sidebar's status glow.
    private static func color(for summary: AttentionSummary) -> NSColor? {
        if summary.needsAttention > 0 { return .systemOrange }
        if summary.working > 0 { return .systemBlue }
        if summary.unread > 0 { return .systemGreen }
        return nil
    }

    private static var images: [NSColor?: NSImage] = [:]

    /// Tinted once per color and kept: the label re-renders with every status change.
    private static func image(for color: NSColor?) -> NSImage {
        if let cached = images[color] { return cached }
        let base = NSImage(resource: .menuBarIslands)
        let image: NSImage
        if let color {
            image = NSImage(size: base.size, flipped: false) { rect in
                base.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            image.isTemplate = false
        } else {
            image = base
            image.isTemplate = true
        }
        image.accessibilityDescription = "Archipel"
        images[color] = image
        return image
    }
}

/// Fades the status item's button in and out while an agent works. This is a layer animation
/// because the glyph is a plain image, so `symbolEffect` can't drive it, and a SwiftUI animation or
/// a timer would redraw the status item on every frame. SwiftUI gives us no handle on the button,
/// so it is looked up in the app's status bar window.
@MainActor
enum StatusItemBreathing {
    private static let key = "archipel.breathing"

    static func update(isWorking: Bool) async {
        // The button may not exist yet when the label first appears.
        for _ in 0..<10 {
            if let layer = button()?.layer {
                apply(isWorking, to: layer)
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
            if Task.isCancelled { return }
        }
    }

    private static func apply(_ isWorking: Bool, to layer: CALayer) {
        guard isWorking else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.45
        fade.duration = 1.4
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: key)
    }

    private static func button() -> NSView? {
        let window = NSApp.windows.first { $0.className == "NSStatusBarWindow" }
        return window?.contentView.flatMap(findButton)
    }

    private static func findButton(in view: NSView) -> NSView? {
        if view is NSStatusBarButton { return view }
        for sub in view.subviews { if let found = findButton(in: sub) { return found } }
        return nil
    }
}

struct MenuBarExtraContent: View {
    @Environment(AppModel.self) private var model

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
            MenuBarButton(title: "Open Archipel", systemImage: "macwindow") { model.showMainWindow() }
            MenuBarButton(title: "Quit Archipel", systemImage: "power") { NSApp.terminate(nil) }
        }
        .padding(6)
        .frame(width: 300)
    }

    private func show(_ id: Session.ID) {
        model.showMainWindow()
        model.select(session: id)
    }
}

private struct MenuBarRow: View {
    let entry: MenuBarEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(symbol: entry.symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .lineLimit(1)
                    Text("\(entry.agentName) · \(entry.location)")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                isHovering || configuration.isPressed ? Color.primary.opacity(0.1) : .clear,
                in: .rect(cornerRadius: Chrome.controlRadius, style: .continuous)
            )
            .onHover { hovering in withAnimation(reduceMotion ? nil : Motion.hover) { isHovering = hovering } }
    }
}

#if DEBUG
private func previewMenuBarModel(_ activities: [Session.ID: SessionActivity]) -> AppModel {
    AppModel(preview: PreviewFixtures.workspace, activities: activities)
}

#Preview("Panel") {
    HStack(alignment: .top, spacing: 16) {
        MenuBarExtraContent().environment(AppModel.preview())
        MenuBarExtraContent().environment(AppModel.emptyPreview())
    }
    .padding()
}

#Preview("Panel, Dark") {
    MenuBarExtraContent()
        .environment(AppModel.preview())
        .preferredColorScheme(.dark)
}

#Preview("Label") {
    let working = SessionActivity(status: .working)
    let unread = SessionActivity(status: .finished, unread: true)
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
        GridRow { MenuBarExtraLabel().environment(AppModel.preview()); Text("Needs you") }
        GridRow { MenuBarExtraLabel().environment(previewMenuBarModel([PreviewFixtures.claudeSessionID: working])); Text("Working") }
        GridRow { MenuBarExtraLabel().environment(previewMenuBarModel([PreviewFixtures.reviewSessionID: unread])); Text("Finished, unread") }
        GridRow { MenuBarExtraLabel().environment(AppModel.emptyPreview()); Text("Nothing going on") }
    }
    .padding()
}
#endif
