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

    // MARK: General

    /// What ⌘T and the plain "new session" buttons start.
    var defaultAgentID: String { didSet { defaults.set(defaultAgentID, forKey: Key.defaultAgentID) } }
    /// Root for new worktrees of projects without a folder of their own: `<root>/<project>/<branch>`.
    var worktreesRoot: URL { didSet { defaults.set(worktreesRoot.path, forKey: Key.worktreesRoot) } }
    /// Prepended to the name typed for a new branch, e.g. `robert/`.
    var branchPrefix: String { didSet { defaults.set(branchPrefix, forKey: Key.branchPrefix) } }
    var confirmsQuitWhileWorking: Bool { didSet { defaults.set(confirmsQuitWhileWorking, forKey: Key.confirmsQuitWhileWorking) } }
    /// Background `git fetch` per project, so behind counts and Pull reflect the remote.
    var fetchesAutomatically: Bool { didSet { defaults.set(fetchesAutomatically, forKey: Key.fetchesAutomatically) } }
    /// Bundle identifier of the editor "Open in Editor" uses. nil picks the first installed one of `ExternalEditor.known`.
    var externalEditorBundleID: String? { didSet { defaults.set(externalEditorBundleID, forKey: Key.externalEditorBundleID) } }

    // MARK: Appearance

    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }
    var showsGitStatusInSidebar: Bool { didSet { defaults.set(showsGitStatusInSidebar, forKey: Key.showsGitStatusInSidebar) } }
    /// Also decides whether `gh` is asked at all.
    var showsPullRequests: Bool { didSet { defaults.set(showsPullRequests, forKey: Key.showsPullRequests) } }
    var showsAgentMessagesInSidebar: Bool { didSet { defaults.set(showsAgentMessagesInSidebar, forKey: Key.showsAgentMessagesInSidebar) } }
    var usageDisplay: UsageDisplay { didSet { defaults.set(usageDisplay.rawValue, forKey: Key.usageDisplay) } }
    var usageBarFill: UsageBarFill { didSet { defaults.set(usageBarFill.rawValue, forKey: Key.usageBarFill) } }

    // MARK: Notifications

    var notifiesWhenAttentionNeeded: Bool { didSet { defaults.set(notifiesWhenAttentionNeeded, forKey: Key.notifiesWhenAttentionNeeded) } }
    var notifiesWhenFinished: Bool { didSet { defaults.set(notifiesWhenFinished, forKey: Key.notifiesWhenFinished) } }
    var notifiesWhenExited: Bool { didSet { defaults.set(notifiesWhenExited, forKey: Key.notifiesWhenExited) } }
    var playsNotificationSound: Bool { didSet { defaults.set(playsNotificationSound, forKey: Key.playsNotificationSound) } }
    var showsDockBadge: Bool { didSet { defaults.set(showsDockBadge, forKey: Key.showsDockBadge) } }
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
        appearance = defaults.string(forKey: Key.appearance).flatMap(Appearance.init) ?? .system
        showsGitStatusInSidebar = bool(Key.showsGitStatusInSidebar, true)
        showsPullRequests = bool(Key.showsPullRequests, true)
        showsAgentMessagesInSidebar = bool(Key.showsAgentMessagesInSidebar, true)
        usageDisplay = defaults.string(forKey: Key.usageDisplay).flatMap(UsageDisplay.init) ?? .numbers
        usageBarFill = defaults.string(forKey: Key.usageBarFill).flatMap(UsageBarFill.init) ?? .used
        notifiesWhenAttentionNeeded = bool(Key.notifiesWhenAttentionNeeded, true)
        notifiesWhenFinished = bool(Key.notifiesWhenFinished, true)
        notifiesWhenExited = bool(Key.notifiesWhenExited, true)
        playsNotificationSound = bool(Key.playsNotificationSound, true)
        showsDockBadge = bool(Key.showsDockBadge, true)
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
        static let appearance = "settings.appearance"
        static let showsGitStatusInSidebar = "settings.showsGitStatusInSidebar"
        static let showsPullRequests = "settings.showsPullRequests"
        static let showsAgentMessagesInSidebar = "settings.showsAgentMessagesInSidebar"
        static let usageDisplay = "settings.usageDisplay"
        static let usageBarFill = "settings.usageBarFill"
        static let notifiesWhenAttentionNeeded = "settings.notifiesWhenAttentionNeeded"
        static let notifiesWhenFinished = "settings.notifiesWhenFinished"
        static let notifiesWhenExited = "settings.notifiesWhenExited"
        static let playsNotificationSound = "settings.playsNotificationSound"
        static let showsDockBadge = "settings.showsDockBadge"
        static let showsMenuBarExtra = "settings.showsMenuBarExtra"
        static let suppressesNotificationsWhileActive = "settings.suppressesNotificationsWhileActive"
        static let holdsNotificationsWhileSharingScreen = "settings.holdsNotificationsWhileSharingScreen"
        static let agentArguments = "settings.agentArguments"
    }
}
