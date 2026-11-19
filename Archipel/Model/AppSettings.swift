import AgentKit
import Foundation
import Observation

/// App-wide preferences, kept in UserDefaults. Per-project choices live on `Project` in the workspace file.
@Observable
final class AppSettings {
    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: Self { self }
    }

    /// How much room each project and worktree gets in the sidebar, like Xcode's navigator size.
    enum SidebarDensity: String, CaseIterable, Identifiable {
        case compact, comfortable, spacious
        var id: Self { self }

        var title: String {
            switch self {
            case .compact: "Compact"
            case .comfortable: "Comfortable"
            case .spacious: "Spacious"
            }
        }
    }

    /// How split panes sit next to each other: flush with a hairline between them, or as rounded
    /// cards with a gap.
    enum PaneStyle: String, CaseIterable, Identifiable {
        case compact, comfortable
        var id: Self { self }

        var title: String {
            switch self {
            case .compact: "Compact"
            case .comfortable: "Comfortable"
            }
        }
    }

    /// How the status bar draws subscription usage.
    enum UsageDisplay: String, CaseIterable, Identifiable {
        case numbers, bars
        var id: Self { self }

        var title: String {
            switch self {
            case .numbers: "Percentages"
            case .bars: "Bars"
            }
        }
    }

    /// Whether a usage bar fills up as the limit is used, or empties as it is, like a battery.
    enum UsageBarFill: String, CaseIterable, Identifiable {
        case used, remaining
        var id: Self { self }

        var title: String {
            switch self {
            case .used: "Used"
            case .remaining: "Remaining"
            }
        }
    }

    /// The items of the status bar, in the order they stand in it.
    enum StatusBarItem: String, CaseIterable, Identifiable {
        case usage, context, agents, resources, stayAwake
        var id: Self { self }

        var title: String {
            switch self {
            case .usage: "Usage limits"
            case .context: "Context & cache"
            case .agents: "Agents"
            case .resources: "Resources"
            case .stayAwake: "Stay awake"
            }
        }

        /// Leading items report on your sessions, trailing ones on the app and the Mac.
        var isLeading: Bool { self == .usage || self == .context }
    }

    /// Where a ⌘-clicked link opens. ⌘⌥-click picks the other one.
    enum LinkDestination: String, CaseIterable, Identifiable {
        case archipel, defaultApp
        var id: Self { self }

        var other: Self { self == .archipel ? .defaultApp : .archipel }
    }

    // MARK: General

    /// What ⌘T and the plain "new session" buttons start.
    var defaultAgentID: String {
        didSet { if !isSuggestingDefaultAgent { defaults.set(defaultAgentID, forKey: Key.defaultAgentID) } }
    }
    /// True once the user picked the default agent themselves. Until then it follows what is installed.
    var hasChosenDefaultAgent: Bool { defaults.string(forKey: Key.defaultAgentID) != nil }
    @ObservationIgnored private var isSuggestingDefaultAgent = false

    /// Makes `id` the default without recording it as the user's choice, so the suggestion can
    /// still change when another agent is installed. Ignored once the user has chosen.
    func suggestDefaultAgent(_ id: String) {
        guard !hasChosenDefaultAgent, defaultAgentID != id else { return }
        isSuggestingDefaultAgent = true
        defaultAgentID = id
        isSuggestingDefaultAgent = false
    }
    /// Root for new worktrees of projects without a folder of their own: `<root>/<project>/<branch>`.
    var worktreesRoot: URL { didSet { defaults.set(worktreesRoot.path, forKey: Key.worktreesRoot) } }
    /// Prepended to the name typed for a new branch, e.g. `alex/`.
    var branchPrefix: String { didSet { defaults.set(branchPrefix, forKey: Key.branchPrefix) } }
    var confirmsQuitWhileWorking: Bool { didSet { defaults.set(confirmsQuitWhileWorking, forKey: Key.confirmsQuitWhileWorking) } }
    /// Background `git fetch` per project, so behind counts and Pull reflect the remote.
    var fetchesAutomatically: Bool { didSet { defaults.set(fetchesAutomatically, forKey: Key.fetchesAutomatically) } }
    /// Bundle identifier of the editor "Open in Editor" uses. nil picks the first installed one of `ExternalEditor.known`.
    var externalEditorBundleID: String? { didSet { defaults.set(externalEditorBundleID, forKey: Key.externalEditorBundleID) } }
    /// Files ⌘-clicked in a terminal.
    var fileLinkDestination: LinkDestination { didSet { defaults.set(fileLinkDestination.rawValue, forKey: Key.fileLinkDestination) } }
    /// Web links ⌘-clicked in a terminal, and the dev server pill.
    var webLinkDestination: LinkDestination { didSet { defaults.set(webLinkDestination.rawValue, forKey: Key.webLinkDestination) } }

    // MARK: Appearance

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var sidebarDensity: SidebarDensity { didSet { defaults.set(sidebarDensity.rawValue, forKey: Key.sidebarDensity) } }
    var paneStyle: PaneStyle { didSet { defaults.set(paneStyle.rawValue, forKey: Key.paneStyle) } }
    var showsGitStatusInSidebar: Bool { didSet { defaults.set(showsGitStatusInSidebar, forKey: Key.showsGitStatusInSidebar) } }
    /// Also decides whether `gh` is asked at all.
    var showsPullRequests: Bool { didSet { defaults.set(showsPullRequests, forKey: Key.showsPullRequests) } }
    var showsAgentMessagesInSidebar: Bool { didSet { defaults.set(showsAgentMessagesInSidebar, forKey: Key.showsAgentMessagesInSidebar) } }
    var usageDisplay: UsageDisplay { didSet { defaults.set(usageDisplay.rawValue, forKey: Key.usageDisplay) } }
    var usageBarFill: UsageBarFill { didSet { defaults.set(usageBarFill.rawValue, forKey: Key.usageBarFill) } }
    /// Hidden rather than shown, so an item added in a later version turns up without the user
    /// having to find it in Settings.
    var hiddenStatusBarItems: Set<StatusBarItem> {
        didSet {
            let stored = hiddenStatusBarItems.map(\.rawValue) + unknownHiddenStatusBarItems
            defaults.set(stored.sorted(), forKey: Key.hiddenStatusBarItems)
        }
    }
    /// Items a newer version hid that this one does not know. Written back as they were, so going
    /// back and forth between versions does not bring them back.
    @ObservationIgnored private var unknownHiddenStatusBarItems: [String] = []

    func shows(_ item: StatusBarItem) -> Bool { !hiddenStatusBarItems.contains(item) }

    func toggle(_ item: StatusBarItem) {
        if shows(item) { hiddenStatusBarItems.insert(item) } else { hiddenStatusBarItems.remove(item) }
    }

    // MARK: Notifications

    var notifiesWhenAttentionNeeded: Bool { didSet { defaults.set(notifiesWhenAttentionNeeded, forKey: Key.notifiesWhenAttentionNeeded) } }
    var notifiesWhenFinished: Bool { didSet { defaults.set(notifiesWhenFinished, forKey: Key.notifiesWhenFinished) } }
    var notifiesWhenExited: Bool { didSet { defaults.set(notifiesWhenExited, forKey: Key.notifiesWhenExited) } }
    var playsNotificationSound: Bool { didSet { defaults.set(playsNotificationSound, forKey: Key.playsNotificationSound) } }
    var showsDockBadge: Bool { didSet { defaults.set(showsDockBadge, forKey: Key.showsDockBadge) } }
    var bouncesDockForAttention: Bool { didSet { defaults.set(bouncesDockForAttention, forKey: Key.bouncesDockForAttention) } }
    var showsMenuBarExtra: Bool { didSet { defaults.set(showsMenuBarExtra, forKey: Key.showsMenuBarExtra) } }
    /// Banners for a session you are not looking at are redundant while Archipel itself is frontmost.
    var suppressesNotificationsWhileActive: Bool {
        didSet { defaults.set(suppressesNotificationsWhileActive, forKey: Key.suppressesNotificationsWhileActive) }
    }
    /// Banners and sounds wait while the screen is shared, then arrive as one summary.
    var holdsNotificationsWhileSharingScreen: Bool {
        didSet { defaults.set(holdsNotificationsWhileSharingScreen, forKey: Key.holdsNotificationsWhileSharingScreen) }
    }

    // MARK: Agents

    /// Extra command line arguments per agent id, as the user typed them.
    var agentArguments: [String: String] { didSet { defaults.set(agentArguments, forKey: Key.agentArguments) } }

    /// The user's extra arguments for an agent, already split into words.
    func extraArguments(for agentID: String) -> [String] {
        ArgumentSplitter.split(agentArguments[agentID] ?? "")
    }

    static let standardWorktreesRoot = URL.homeDirectory.appending(path: ".archipel/worktrees", directoryHint: .isDirectory)

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        defaultAgentID = defaults.string(forKey: Key.defaultAgentID) ?? "claude"
        worktreesRoot = defaults.string(forKey: Key.worktreesRoot)
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Self.standardWorktreesRoot
        branchPrefix = defaults.string(forKey: Key.branchPrefix) ?? ""
        confirmsQuitWhileWorking = bool(Key.confirmsQuitWhileWorking, true)
        fetchesAutomatically = bool(Key.fetchesAutomatically, true)
        externalEditorBundleID = defaults.string(forKey: Key.externalEditorBundleID)
        fileLinkDestination = defaults.string(forKey: Key.fileLinkDestination).flatMap(LinkDestination.init) ?? .archipel
        // The browser stays the default for web links: it has the user's logins and extensions.
        webLinkDestination = defaults.string(forKey: Key.webLinkDestination).flatMap(LinkDestination.init) ?? .defaultApp
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        sidebarDensity = defaults.string(forKey: Key.sidebarDensity).flatMap(SidebarDensity.init) ?? .comfortable
        paneStyle = defaults.string(forKey: Key.paneStyle).flatMap(PaneStyle.init) ?? .comfortable
        showsGitStatusInSidebar = bool(Key.showsGitStatusInSidebar, true)
        showsPullRequests = bool(Key.showsPullRequests, true)
        showsAgentMessagesInSidebar = bool(Key.showsAgentMessagesInSidebar, true)
        usageDisplay = defaults.string(forKey: Key.usageDisplay).flatMap(UsageDisplay.init) ?? .numbers
        usageBarFill = defaults.string(forKey: Key.usageBarFill).flatMap(UsageBarFill.init) ?? .used
        let hidden = defaults.stringArray(forKey: Key.hiddenStatusBarItems) ?? []
        hiddenStatusBarItems = Set(hidden.compactMap(StatusBarItem.init))
        unknownHiddenStatusBarItems = hidden.filter { StatusBarItem(rawValue: $0) == nil }
        notifiesWhenAttentionNeeded = bool(Key.notifiesWhenAttentionNeeded, true)
        notifiesWhenFinished = bool(Key.notifiesWhenFinished, true)
        notifiesWhenExited = bool(Key.notifiesWhenExited, true)
        playsNotificationSound = bool(Key.playsNotificationSound, true)
        showsDockBadge = bool(Key.showsDockBadge, true)
        bouncesDockForAttention = bool(Key.bouncesDockForAttention, false)
        showsMenuBarExtra = bool(Key.showsMenuBarExtra, true)
        suppressesNotificationsWhileActive = bool(Key.suppressesNotificationsWhileActive, false)
        holdsNotificationsWhileSharingScreen = bool(Key.holdsNotificationsWhileSharingScreen, true)
        agentArguments = defaults.dictionary(forKey: Key.agentArguments) as? [String: String] ?? [:]
    }

    private enum Key {
        static let defaultAgentID = "settings.defaultAgentID"
        static let worktreesRoot = "settings.worktreesRoot"
        static let branchPrefix = "settings.branchPrefix"
        static let confirmsQuitWhileWorking = "settings.confirmsQuitWhileWorking"
        static let fetchesAutomatically = "settings.fetchesAutomatically"
        static let externalEditorBundleID = "settings.externalEditorBundleID"
        static let fileLinkDestination = "settings.fileLinkDestination"
        static let webLinkDestination = "settings.webLinkDestination"
        static let appearance = "settings.appearance"
        static let sidebarDensity = "settings.sidebarDensity"
        static let paneStyle = "settings.paneStyle"
        static let showsGitStatusInSidebar = "settings.showsGitStatusInSidebar"
        static let showsPullRequests = "settings.showsPullRequests"
        static let showsAgentMessagesInSidebar = "settings.showsAgentMessagesInSidebar"
        static let usageDisplay = "settings.usageDisplay"
        static let usageBarFill = "settings.usageBarFill"
        static let hiddenStatusBarItems = "settings.hiddenStatusBarItems"
        static let notifiesWhenAttentionNeeded = "settings.notifiesWhenAttentionNeeded"
        static let notifiesWhenFinished = "settings.notifiesWhenFinished"
        static let notifiesWhenExited = "settings.notifiesWhenExited"
        static let playsNotificationSound = "settings.playsNotificationSound"
        static let bouncesDockForAttention = "settings.bouncesDockForAttention"
        static let showsDockBadge = "settings.showsDockBadge"
        static let showsMenuBarExtra = "settings.showsMenuBarExtra"
        static let suppressesNotificationsWhileActive = "settings.suppressesNotificationsWhileActive"
        static let holdsNotificationsWhileSharingScreen = "settings.holdsNotificationsWhileSharingScreen"
        static let agentArguments = "settings.agentArguments"
    }
}
