import AgentKit
import AppKit
import ArchipelCore
import SwiftUI

/// Quick Look for sessions: with the sidebar focused, Space shows the end of
/// the terminal under the pointer without switching to it.
///
/// The pointer picks the row, not the list selection, because selecting a
/// row in the sidebar already switches the content area; peeking at the
/// selection would only show what is on screen anyway. While the peek is open
/// the arrow keys step through the rows without selecting them, Return opens
/// the peeked session for real, and Space or Escape closes it.
@Observable
final class SidebarPeekModel {
    private(set) var target: SessionPeek.Target?

    // Hover changes on every pointer move over the list; nothing redraws from it.
    @ObservationIgnored private var hoveredWorktree: Worktree.ID?
    @ObservationIgnored private var hoveredSession: Session.ID?

    var isOpen: Bool { target != nil }

    /// True between the popover appearing and disappearing. `target` alone says a peek was
    /// requested, not that anything is on screen to take keys for.
    @ObservationIgnored private(set) var isPresented = false

    func popoverAppeared() { isPresented = true }

    func popoverDisappeared() { isPresented = false }

    /// The popover disappears without calling its binding setter when its anchor row goes away
    /// (island switch, removed worktree), so the target is checked against the live rows instead.
    func closeIfStale(in model: AppModel) {
        guard let target else { return }
        guard let island = model.selectedIsland,
              SessionPeek.targets(in: island, relevantSession: { model.peekSession(in: $0) }).contains(where: { $0.worktreeID == target.worktreeID })
        else {
            close()
            return
        }
    }

    func hover(worktree id: Worktree.ID, _ inside: Bool) {
        // Entering the next row can be reported before leaving the last one.
        if inside {
            hoveredWorktree = id
        } else if hoveredWorktree == id {
            hoveredWorktree = nil
        }
    }

    func hover(session id: Session.ID, _ inside: Bool) {
        if inside {
            hoveredSession = id
        } else if hoveredSession == id {
            hoveredSession = nil
        }
    }

    /// False when the pointer is not over a row, so the key goes on to the list.
    func openHovered(in model: AppModel) -> Bool {
        if let id = hoveredSession, let worktree = model.workspace.worktree(containing: id) {
            target = SessionPeek.Target(worktreeID: worktree.id, sessionID: id)
        } else if let id = hoveredWorktree, let worktree = model.workspace.worktree(id: id) {
            target = SessionPeek.Target(worktreeID: id, sessionID: model.peekSession(in: worktree))
        } else {
            return false
        }
        return true
    }

    func step(by offset: Int, in model: AppModel) {
        guard let target, let island = model.selectedIsland else { return }
        let targets = SessionPeek.targets(in: island) { model.peekSession(in: $0) }
        self.target = SessionPeek.step(from: target, by: offset, in: targets) ?? target
    }

    func openTarget(in model: AppModel) {
        guard let target else { return }
        close()
        if let session = target.sessionID {
            model.select(session: session)
        } else {
            model.select(worktree: target.worktreeID)
        }
    }

    func close() {
        target = nil
    }

    /// Drives the popover on one worktree row.
    func isPresented(for worktree: Worktree.ID) -> Binding<Bool> {
        Binding(
            get: { self.target?.worktreeID == worktree },
            set: { shown in
                // A popover being dismissed because the peek moved to another row
                // must not close the peek that replaced it.
                if !shown, self.target?.worktreeID == worktree { self.close() }
            }
        )
    }
}

extension AppModel {
    func peekSession(in worktree: Worktree) -> Session.ID? {
        SessionPeek.mostRelevantSession(
            in: worktree,
            activities: activities,
            focusedSessionID: workspace.focusedSessionID(in: worktree.id),
            isLive: { terminals[$0] != nil }
        )
    }
}

extension View {
    /// Attaches the peek's popover to a worktree row and reports hover for it.
    func sidebarPeek(_ peek: SidebarPeekModel, worktree: Worktree.ID) -> some View {
        onHover { peek.hover(worktree: worktree, $0) }
            .popover(isPresented: peek.isPresented(for: worktree), arrowEdge: .trailing) {
                if let target = peek.target {
                    SessionPeekView(target: target)
                        .onAppear { peek.popoverAppeared() }
                        .onDisappear { peek.popoverDisappeared() }
                }
            }
    }
}

/// The popover's content: who the session is, what it is doing, and the last
/// lines of its terminal, refreshed while it is open.
struct SessionPeekView: View {
    @Environment(AppModel.self) private var model
    let target: SessionPeek.Target

    static let lineCount = 25

    var body: some View {
        let session = target.sessionID.flatMap { model.workspace.session(id: $0) }
        VStack(alignment: .leading, spacing: 0) {
            header(session)
            Divider()
            output(session)
        }
        .frame(width: 600)
    }

    private func header(_ session: Session?) -> some View {
        let activity = session.map { model.activity(for: $0.id) }
        return HStack(spacing: 10) {
            Image(symbol: (session?.agent.definition ?? .shell).symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(session?.displayTitle ?? model.workspace.worktree(id: target.worktreeID)?.displayName ?? "Session")
                    .font(.headline)
                    .lineLimit(1)
                Text(subtitle(activity))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let activity, activity.status != .notStarted {
                StatusGlyph(activity: activity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func subtitle(_ activity: SessionActivity?) -> String {
        let place = model.workspace.worktree(id: target.worktreeID)?.displayName
        guard let activity else { return place ?? "" }
        return [activity.status.label, place].compactMap(\.self).joined(separator: " · ")
    }

    @ViewBuilder
    private func output(_ session: Session?) -> some View {
        if let session, let terminal = model.terminals[session.id] {
            // Ghostty has no change notification, so the peek polls like the
            // dev server monitor does; it only runs while the popover is up.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let lines = SessionPeek.tail(of: terminal.readVisibleText(), lines: Self.lineCount)
                ScrollView([.vertical, .horizontal]) {
                    Text(verbatim: lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .defaultScrollAnchor(.bottomLeading)
                .frame(height: 360)
            }
        } else {
            placeholder(session)
        }
    }

    private func placeholder(_ session: Session?) -> some View {
        let message: String
        if session == nil {
            message = "This worktree has no sessions yet."
        } else if let failure = session.flatMap({ model.launchFailures[$0.id] }) {
            message = failure
        } else {
            message = "This session is not running. Open it to start it."
        }
        return Text(message)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: 80)
            .padding(12)
    }
}

/// Listens for the peek's keys. Space only opens a peek while keyboard focus
/// is in the sidebar, so terminals, editors and text fields keep it; once a
/// peek is open its keys are taken wherever focus is, since the popover may
/// have become the key window.
struct SidebarPeekKeyMonitor: NSViewRepresentable {
    let peek: SidebarPeekModel
    let model: AppModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.peek = peek
        view.model = model
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.peek = peek
        view.model = model
    }

    final class MonitorView: LocalKeyMonitorView {
        weak var peek: SidebarPeekModel?
        weak var model: AppModel?

        private enum Key {
            static let space: UInt16 = 49
            static let escape: UInt16 = 53
            static let returnKey: UInt16 = 36
            static let enter: UInt16 = 76
            static let up: UInt16 = 126
            static let down: UInt16 = 125
        }

        override func handle(_ event: NSEvent) -> Bool {
            guard let peek, let model else { return false }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if peek.isOpen {
                peek.closeIfStale(in: model)
                // A peek whose popover is gone, or while another window is key, must not eat keys.
                guard peek.isOpen, peek.isPresented, keyWindowBelongsToUs else { return false }
                guard modifiers.isEmpty else {
                    peek.close()
                    return false
                }
                switch event.keyCode {
                case Key.space, Key.escape: peek.close()
                case Key.up: peek.step(by: -1, in: model)
                case Key.down: peek.step(by: 1, in: model)
                case Key.returnKey, Key.enter: peek.openTarget(in: model)
                default:
                    peek.close()
                    return false
                }
                return true
            }
            guard event.keyCode == Key.space, modifiers.isEmpty, !event.isARepeat,
                  event.window === window, sidebarHasKeyboardFocus
            else { return false }
            return peek.openHovered(in: model)
        }

        /// The popover may be the key window, so a child window of ours counts too.
        private var keyWindowBelongsToUs: Bool {
            guard let window, let key = NSApp.keyWindow else { return false }
            return key === window || key.parent === window || window.childWindows?.contains(key) == true
        }

        /// This view backs the sidebar's list, so a first responder that sits
        /// inside its frame is the list (or a control in the sidebar). Text
        /// editing goes through a field editor, which is never ours to take.
        private var sidebarHasKeyboardFocus: Bool {
            guard let window, let responder = window.firstResponder as? NSView, !(responder is NSText) else { return false }
            let sidebar = convert(bounds, to: nil)
            let focused = (responder.enclosingScrollView ?? responder).convert(
                (responder.enclosingScrollView ?? responder).bounds, to: nil)
            return sidebar.contains(CGPoint(x: focused.midX, y: focused.midY))
        }
    }
}
