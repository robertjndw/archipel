import AgentKit
import AppKit
import ArchipelCore
import SwiftUI
import TerminalKit

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

    /// Which popovers are on screen. `target` alone says a peek was requested, not that anything
    /// is on screen to take keys for.
    @ObservationIgnored private var presentation = SessionPeek.Presentation()

    var isPresented: Bool { presentation.isShowing() }

    func popoverAppeared(for worktree: Worktree.ID) { presentation.appeared(worktree) }

    func popoverDisappeared(for worktree: Worktree.ID) {
        presentation.disappeared(worktree)
        snapshotSources[worktree] = nil
    }

    func setSnapshotSource(_ view: NSView, for worktree: Worktree.ID) {
        snapshotSources[worktree] = WeakView(view: view)
    }

    struct WeakView {
        weak var view: NSView?
    }

    /// The views behind each popover's content, which Return photographs for the zoom. Per row,
    /// since the popover being stepped away from can still update after the new one has appeared.
    @ObservationIgnored private var snapshotSources: [Worktree.ID: WeakView] = [:]
    @ObservationIgnored private let zoom = PeekZoom()

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
        SidebarTips.peeked()
        return true
    }

    func step(by offset: Int, in model: AppModel) {
        guard let target, let island = model.selectedIsland else { return }
        let targets = SessionPeek.targets(in: island) { model.peekSession(in: $0) }
        let next = SessionPeek.step(from: target, by: offset, in: targets) ?? target
        if next.worktreeID != target.worktreeID { presentation.moving(to: next.worktreeID) }
        self.target = next
    }

    /// Opens the peeked session, growing the peek into the pane that shows it when there is a
    /// popover to start from.
    func openTarget(in model: AppModel, window: NSWindow?) {
        guard let target else { return }
        // Taken before closing: once the popover starts to go away there is nothing left to draw.
        let snapshot = snapshotSources[target.worktreeID]?.view?.peekSnapshot()
        close()
        let select = {
            if let session = target.sessionID {
                model.select(session: session)
            } else {
                model.select(worktree: target.worktreeID)
            }
        }
        guard let snapshot, let window else { return select() }
        zoom.run(
            from: snapshot,
            over: window,
            background: PaneSurface(target: target, in: model).color,
            select: select,
            destination: { [weak model, weak window] in
                guard let model, let window else { return nil }
                return model.peekZoomDestination(for: target, in: window)
            }
        )
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
    /// The pane that shows the peeked session once it has been selected. Nil until the selection has
    /// landed there and SwiftUI has laid the pane out, or if it never does.
    fileprivate func peekZoomDestination(for target: SessionPeek.Target, in window: NSWindow) -> PeekZoomDestination? {
        guard let worktree = selectedWorktree, worktree.id == target.worktreeID else { return nil }
        let pane: Pane?
        if let session = target.sessionID {
            pane = worktree.panes.first { $0.selectedTab?.content == .session(session) }
        } else {
            pane = worktree.focusedPane
        }
        guard let pane, let frame = paneFrames[pane.id], frame.width > 1, frame.height > 1 else { return nil }
        let windowRadius = window.cornerRadius ?? WindowMetrics().cornerRadius
        let radius = Chrome.paneRadius(for: settings.paneStyle, windowRadius: windowRadius)
        return PeekZoomDestination(frame: frame, radius: radius)
    }

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
                        .background { PeekSnapshotSource(peek: peek, worktree: worktree) }
                        .onAppear { peek.popoverAppeared(for: worktree) }
                        .onDisappear { peek.popoverDisappeared(for: worktree) }
                }
            }
    }
}

extension PaneSurface {
    /// The surface the pane would show this target on: the terminal's for a session, the text
    /// background for a worktree without sessions.
    @MainActor
    init(target: SessionPeek.Target, in model: AppModel) {
        self.init(showsSession: target.sessionID != nil, colors: model.terminalColors)
    }
}

/// The popover's content: who the session is, what it is doing, and the last lines of its terminal,
/// refreshed while it is open. It uses the terminal's colors so it looks like the pane Return opens,
/// which is what lets the zoom land without a jump in color.
struct SessionPeekView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let target: SessionPeek.Target

    static let lineCount = 30

    var body: some View {
        let session = target.sessionID.flatMap { model.workspace.session(id: $0) }
        let surface = PaneSurface(target: target, in: model)
        VStack(alignment: .leading, spacing: 0) {
            header(session)
            output(session, surface: surface)
            hints
        }
        .frame(width: 640)
        .background(surface.color)
        .presentationBackground(surface.color)
        .environment(\.colorScheme, surface.colorScheme ?? colorScheme)
    }

    private func header(_ session: Session?) -> some View {
        let activity = session.map { model.activity(for: $0.id) }
        let tint = model.project(ofWorktree: target.worktreeID).map { model.tint(of: $0).color }
        return HStack(spacing: 10) {
            Image(symbol: (session.map { model.effectiveAgent(for: $0).definition } ?? .shell).symbolName)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(session?.displayTitle ?? model.workspace.worktree(id: target.worktreeID)?.displayName ?? "Session")
                    .font(.headline)
                    .lineLimit(1)
                    .accessibilityIdentifier("sidebar.peek.title")
                subtitle(activity)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let activity, activity.status != .notStarted {
                StatusGlyph(activity: activity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    /// Only a session waiting for the user gets a color, the same orange the sidebar uses.
    private func subtitle(_ activity: SessionActivity?) -> Text {
        let place = model.workspace.worktree(id: target.worktreeID)?.displayName ?? ""
        guard let activity else { return Text(place).foregroundStyle(.secondary) }
        let status = Text(activity.status.label)
            .foregroundStyle(activity.needsUser ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        guard !place.isEmpty else { return status }
        let rest = Text(verbatim: " · \(place)").foregroundStyle(.secondary)
        return Text("\(status)\(rest)")
    }

    @ViewBuilder
    private func output(_ session: Session?, surface: PaneSurface) -> some View {
        if let session, let terminal = model.terminals[session.id] {
            PeekTail(foreground: surface.foreground) {
                SessionPeek.tail(of: terminal.readVisibleText(), lines: Self.lineCount).joined(separator: "\n")
            }
            .id(session.id)
            .frame(height: 380)
        } else {
            placeholder(session)
                .frame(height: 220)
        }
    }

    private func placeholder(_ session: Session?) -> some View {
        Group {
            if session == nil {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "terminal",
                    description: Text("This worktree has no sessions yet.")
                )
            } else if let failure = session.flatMap({ model.launchFailures[$0.id] }) {
                ContentUnavailableView("Could Not Start", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else {
                ContentUnavailableView(
                    "Not Running",
                    systemImage: "pause.circle",
                    description: Text("Open this session to start it.")
                )
            }
        }
        .controlSize(.small)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)
            Text("↩ Open")
            Text("↑↓ Browse")
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 9)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}

/// The end of a terminal's text, pinned to the bottom like the prompt and faded at the top, because
/// there is usually more output above it.
struct PeekTail: View {
    let foreground: Color
    let read: () -> String
    @State private var text = ""

    var body: some View {
        // No scroll view: a fixed-size text anchored to the bottom just overflows upward and is
        // clipped, so a refresh never moves anything that did not change.
        Text(verbatim: text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(foreground)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .clipped()
            .mask {
                LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.22)], startPoint: .top, endPoint: .bottom)
            }
            // Ghostty has no change notification, so the peek polls like the dev server monitor does;
            // it only runs while the popover is up, and only touches the view when the text changed.
            // Not in init: init runs on every update of the peeked session, and each call would read
            // the whole viewport only for State to throw it away. onAppear still runs before the
            // first frame, so the zoom's snapshot has the text.
            .onAppear { text = read() }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let latest = read()
                    if latest != text { text = latest }
                }
            }
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
                case Key.returnKey, Key.enter: peek.openTarget(in: model, window: window)
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

#if DEBUG
// Previews never have a live terminal, so the peek shows its placeholder instead of output.
#Preview("Running") {
    let lines = (1...40).map { "\($0)  compiling module \($0 % 7 == 0 ? "ArchipelCore" : "AgentKit") (\($0 * 3)ms)" }
    return VStack(spacing: 0) {
        PeekTail(foreground: .primary) { lines.suffix(SessionPeekView.lineCount).joined(separator: "\n") }
            .frame(width: 640, height: 380)
    }
    .background(Color(nsColor: .textBackgroundColor))
}

#Preview("Session not running") {
    SessionPeekView(target: SessionPeek.Target(worktreeID: PreviewFixtures.featureWorktreeID, sessionID: PreviewFixtures.codexSessionID))
        .environment(AppModel.preview())
}

#Preview("Session could not start") {
    SessionPeekView(target: SessionPeek.Target(worktreeID: PreviewFixtures.mainWorktreeID, sessionID: PreviewFixtures.claudeSessionID))
        .environment(AppModel.launchFailurePreview())
}

#Preview("Worktree without sessions") {
    SessionPeekView(target: SessionPeek.Target(worktreeID: PreviewFixtures.blogWorktreeID, sessionID: nil))
        .environment(AppModel.preview())
}
#endif
