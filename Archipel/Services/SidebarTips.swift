import ArchipelCore
import ChatUI
import SwiftUI
import TipKit

/// Hints for the sidebar features that have no visible control. They share one group so at most one
/// popover is up at a time; the next one waits until the current is invalidated or dismissed.
enum SidebarTips {
    static let group = TipGroup(.firstAvailable) {
        PeekTip()
        IslandSwipeTip()
        NeedsMeTip()
        // Not a sidebar feature, but in the group so it never pops up beside one of the others.
        ChatTip()
        // The chat's own tips, for the same reason. Last, since a chat is there to be read and
        // typed into, and a popover on its composer can wait for everything else.
        ChatTips.all
    }

    @Parameter static var worktreeCount: Int = 0
    @Parameter static var islandCount: Int = 0
    // These two say that a sidebar tip has a place to show right now, as the chat's tips say of
    // theirs. A tip without one is still the group's current tip, and holds up every tip after
    // it for as long as the sidebar stays hidden.
    @Parameter(.transient) static var isSidebarVisible: Bool = false
    @Parameter(.transient) static var isIslandSwitcherVisible: Bool = false

    nonisolated fileprivate static let worktreeSwitchEvent = Tips.Event(id: "worktreeSwitched")
    nonisolated fileprivate static let agentWaitedEvent = Tips.Event(id: "agentWaited")
    nonisolated fileprivate static let terminalSessionStartedEvent = Tips.Event(id: "terminalSessionStarted")

    // Kept as functions so the model does not need TipKit, whose Tab collides with the app's own.
    // Every donation is a write to TipKit's store. Once the tip is gone there's no point.
    static func worktreeSwitched() {
        if case .invalidated = PeekTip().status { return }
        Task { await worktreeSwitchEvent.donate() }
    }
    static func agentWaited() {
        if case .invalidated = NeedsMeTip().status { return }
        Task { await agentWaitedEvent.donate() }
    }
    /// A new terminal session of an agent that could have opened as a chat.
    static func terminalSessionStarted() {
        if case .invalidated = ChatTip().status { return }
        Task { await terminalSessionStartedEvent.donate() }
    }
    static func workspaceChanged(_ workspace: Workspace) {
        let islands = workspace.islands.count
        let worktrees = workspace.islands.reduce(0) { $0 + $1.projects.reduce(0) { $0 + $1.worktrees.count } }
        if islandCount != islands { islandCount = islands }
        if worktreeCount != worktrees { worktreeCount = worktrees }
    }
    static func sidebarVisibilityChanged(_ isVisible: Bool) {
        if isSidebarVisible != isVisible { isSidebarVisible = isVisible }
    }
    static func islandSwitcherVisibilityChanged(_ isVisible: Bool) {
        if isIslandSwitcherVisible != isVisible { isIslandSwitcherVisible = isVisible }
    }
    static func peeked() { PeekTip().invalidate(reason: .actionPerformed) }
    static func islandSwitched() { IslandSwipeTip().invalidate(reason: .actionPerformed) }
    static func needsMeFilterUsed() { NeedsMeTip().invalidate(reason: .actionPerformed) }
    static func chatOpened() { ChatTip().invalidate(reason: .actionPerformed) }

    /// Called once at launch. The store sits in the support folder so builds with another support
    /// directory (Debug, UI tests, throwaway runs) do not share what the user has already seen.
    static func configure() {
        #if UITESTS
        // A popover would sit on top of the controls the tests click. A build of this
        // configuration that is driven by hand asks for the tips with ARCHIPEL_SHOW_TIPS=1;
        // it is the only way to see them beside the user's own Archipel.
        guard ProcessInfo.processInfo.environment["ARCHIPEL_SHOW_TIPS"] == "1" else {
            Tips.hideAllTipsForTesting()
            return
        }
        #endif
        let directory = AppModel.supportDirectory.appending(path: "Tips", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Tips.configure([.datastoreLocation(.url(directory))])
        // The chat asks this group which of its tips is due, instead of a group of its own.
        ChatTips.hostGroup = group
    }
}

struct PeekTip: Tip {
    var title: Text { Text("Peek at a Session") }
    var message: Text? { Text("Hover a worktree and press Space to see its terminal without switching.") }
    var image: Image? { Image(systemName: "eye") }

    var rules: [Rule] {
        #Rule(SidebarTips.$isSidebarVisible) { $0 }
        #Rule(SidebarTips.$worktreeCount) { $0 >= 2 }
        #Rule(SidebarTips.worktreeSwitchEvent) { $0.donations.count >= 3 }
    }
}

struct IslandSwipeTip: Tip {
    var title: Text { Text("Switch Islands") }
    var message: Text? { Text("Swipe with two fingers over the sidebar, or press ⌃1 to ⌃9.") }
    var image: Image? { Image(systemName: "square.on.square") }

    var rules: [Rule] {
        #Rule(SidebarTips.$isSidebarVisible) { $0 }
        #Rule(SidebarTips.$isIslandSwitcherVisible) { $0 }
        #Rule(SidebarTips.$islandCount) { $0 >= 2 }
    }
}

struct NeedsMeTip: Tip {
    var title: Text { Text("Focus on What Needs You") }
    var message: Text? { Text("Show only the worktrees waiting for you, from every island, and jump to the next one.") }
    var image: Image? { Image(systemName: "bell") }

    var rules: [Rule] {
        #Rule(SidebarTips.$isSidebarVisible) { $0 }
        #Rule(SidebarTips.agentWaitedEvent) { $0.donations.count >= 1 }
    }
}

/// Shown on the tab bar's plus button. Three terminal sessions in, the user has a habit worth
/// offering an alternative to, and the plus button is where the next one starts.
struct ChatTip: Tip {
    var title: Text { Text("Open a Session as a Chat") }
    var message: Text? { Text("See the conversation as a chat instead of a terminal. Right-click a session's tab and choose Switch to Chat, or make Chat the default in Settings > Agents.") }
    var image: Image? { Image(systemName: "bubble.left.and.text.bubble.right") }

    var rules: [Rule] {
        #Rule(SidebarTips.terminalSessionStartedEvent) { $0.donations.count >= 3 }
    }
}

/// The default tip style is too big next to a Mac sidebar and looks like a dialog. Same parts here,
/// at roughly the size of a help tag.
struct CompactTipStyle: TipViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.image?
                .font(.callout)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                configuration.title
                    .font(.callout.weight(.semibold))
                configuration.message?
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                configuration.tip.invalidate(reason: .tipClosed)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Close")
        }
        .frame(width: 240, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}
