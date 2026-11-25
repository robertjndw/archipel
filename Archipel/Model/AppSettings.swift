import AgentKit
import ArchipelCore
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
    /// Adds Archipel's hook entries to the user's Claude settings so a Claude started by hand in a
    /// shell tab reports its status. Off until the user asks, since it edits a file they own.
    var claudeUserHooksEnabled: Bool { didSet { defaults.set(claudeUserHooksEnabled, forKey: Key.claudeUserHooksEnabled) } }
    /// The settings file the entries were written to. CLAUDE_CONFIG_DIR is read from a login shell,
    /// which can time out, so checks and removal use this path instead of guessing again.
    var claudeUserHooksFilePath: String? { didSet { defaults.set(claudeUserHooksFilePath, forKey: Key.claudeUserHooksFilePath) } }
    /// The Codex hook command the latest Codex sessions reported through, which means the user
    /// trusts it. A different command (the path changed) has to be trusted again, and it is
    /// cleared when a session finishes a turn without its hooks: the trust was taken back.
    var codexHooksTrustedCommand: String? { didSet { defaults.set(codexHooksTrustedCommand, forKey: Key.codexHooksTrustedCommand) } }
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

    /// Named argument sets for File > New Session with Preset, in the user's order.
    var launchPresets: [LaunchPreset] {
        didSet {
            defaults.set(try? JSONEncoder().encode(launchPresets), forKey: Key.launchPresets)
            // Deleting the default preset leaves the agent without one rather than pointing at nothing.
            let ids = Set(launchPresets.map(\.id))
            if defaultPresetIDs.values.contains(where: { !ids.contains($0) }) {
                defaultPresetIDs = defaultPresetIDs.filter { ids.contains($0.value) }
            }
        }
    }

    /// The preset New Session (⌘T) uses, per agent id. An agent without one starts with no extra
    /// arguments.
    private(set) var defaultPresetIDs: [String: UUID] {
        didSet { defaults.set(defaultPresetIDs.mapValues(\.uuidString), forKey: Key.defaultPresetIDs) }
    }

    func defaultPreset(for agentID: String) -> LaunchPreset? {
        guard let id = defaultPresetIDs[agentID] else { return nil }
        return launchPresets.first { $0.id == id }
    }

    /// Nil clears the agent's default.
    func setDefaultPreset(_ id: LaunchPreset.ID?, for agentID: String) {
        defaultPresetIDs[agentID] = id
    }

    /// The default preset's arguments for an agent, already split into words.
    func extraArguments(for agentID: String) -> [String] {
        ArgumentSplitter.split(defaultPreset(for: agentID)?.arguments ?? "")
    }

    /// Per agent id. An agent without an entry uses the defaults, so a newly added agent shows up
    /// enabled. Entries for ids this version does not know stay in place for the version that does.
    private(set) var agentPreferences: [String: AgentPreferences] {
        didSet { defaults.set(try? JSONEncoder().encode(agentPreferences), forKey: Key.agentPreferences) }
    }

    func isEnabled(_ agentID: String) -> Bool {
        agentPreferences[agentID]?.isEnabled ?? true
    }

    /// Stores the switch as asked. Keeping one agent enabled and moving the default away from a
    /// disabled one is up to `AppModel.setEnabled(_:for:)`, which knows the registry.
    func setEnabled(_ enabled: Bool, for agentID: String) {
        agentPreferences[agentID, default: AgentPreferences()].isEnabled = enabled
    }

    /// The executable the user chose for an agent instead of the one found on the PATH.
    func executablePath(for agentID: String) -> String? {
        agentPreferences[agentID]?.executablePath
    }

    /// Nil goes back to looking the agent up on the PATH.
    func setExecutablePath(_ path: String?, for agentID: String) {
        agentPreferences[agentID, default: AgentPreferences()].executablePath = path.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Whether new sessions of an agent start as a terminal or as a chat.
    func interface(for agentID: String) -> SessionInterface {
        agentPreferences[agentID]?.interface ?? .terminal
    }

    func setInterface(_ interface: SessionInterface, for agentID: String) {
        agentPreferences[agentID, default: AgentPreferences()].interface = interface
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
        claudeUserHooksEnabled = bool(Key.claudeUserHooksEnabled, false)
        claudeUserHooksFilePath = defaults.string(forKey: Key.claudeUserHooksFilePath)
        codexHooksTrustedCommand = defaults.string(forKey: Key.codexHooksTrustedCommand)
        showsMenuBarExtra = bool(Key.showsMenuBarExtra, true)
        suppressesNotificationsWhileActive = bool(Key.suppressesNotificationsWhileActive, false)
        holdsNotificationsWhileSharingScreen = bool(Key.holdsNotificationsWhileSharingScreen, true)
        agentPreferences = defaults.data(forKey: Key.agentPreferences).map(AgentPreferences.decodeAll(from:)) ?? [:]
        // Seeded only while the key is missing, so a list the user emptied stays empty. Data that
        // no longer decodes also falls back to the defaults rather than losing the menu.
        let presets = defaults.data(forKey: Key.launchPresets)
            .flatMap { try? JSONDecoder().decode([LaunchPreset].self, from: $0) } ?? LaunchPreset.defaults
        if let stored = defaults.dictionary(forKey: Key.defaultPresetIDs) as? [String: String] {
            launchPresets = presets
            defaultPresetIDs = stored.compactMapValues(UUID.init(uuidString:))
        } else {
            // First launch since presets replaced the "Extra arguments" field. Writing the new key
            // here makes this run only once.
            let old = defaults.dictionary(forKey: Key.agentArguments) as? [String: String] ?? [:]
            let migrated = LaunchPreset.migrating(extraArguments: old, into: presets)
            launchPresets = migrated.presets
            defaultPresetIDs = migrated.defaultIDs
            if !old.isEmpty { defaults.set(try? JSONEncoder().encode(launchPresets), forKey: Key.launchPresets) }
            defaults.set(defaultPresetIDs.mapValues(\.uuidString), forKey: Key.defaultPresetIDs)
            defaults.removeObject(forKey: Key.agentArguments)
        }
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
        static let claudeUserHooksEnabled = "settings.claudeUserHooksEnabled"
        static let claudeUserHooksFilePath = "settings.claudeUserHooksFilePath"
        static let codexHooksTrustedCommand = "settings.codexHooksTrustedCommand"
        static let showsMenuBarExtra = "settings.showsMenuBarExtra"
        static let suppressesNotificationsWhileActive = "settings.suppressesNotificationsWhileActive"
        static let holdsNotificationsWhileSharingScreen = "settings.holdsNotificationsWhileSharingScreen"
        static let agentArguments = "settings.agentArguments"
        static let launchPresets = "settings.launchPresets"
        static let defaultPresetIDs = "settings.defaultPresetIDs"
        static let agentPreferences = "settings.agentPreferences"
    }
}

/// What the user set for one agent in Settings > Agents.
struct AgentPreferences: Codable, Equatable {
    /// Whether New Session menus, buttons and the palette offer the agent. Sessions that already
    /// exist keep running and resuming either way.
    var isEnabled = true
    /// Nil finds the agent on the login PATH.
    var executablePath: String?
    /// What a new session of the agent starts as.
    var interface: SessionInterface = .terminal

    init(isEnabled: Bool = true, executablePath: String? = nil, interface: SessionInterface = .terminal) {
        self.isEnabled = isEnabled
        self.executablePath = executablePath
        self.interface = interface
    }

    /// Each field falls back on its own, so a value of the wrong type or a field written by a newer
    /// version does not throw the whole entry away.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .isEnabled)) ?? true
        executablePath = (try? container.decodeIfPresent(String.self, forKey: .executablePath)) ?? nil
        // A string, so an interface from a later version falls back to the terminal.
        interface = ((try? container.decodeIfPresent(String.self, forKey: .interface)) ?? nil)
            .flatMap(SessionInterface.init(rawValue:)) ?? .terminal
    }

    /// Decodes the stored dictionary entry by entry: one broken entry costs only that agent its
    /// preferences, and data that is not a dictionary at all means defaults for everyone.
    static func decodeAll(from data: Data) -> [String: AgentPreferences] {
        let entries = (try? JSONDecoder().decode([String: Lenient].self, from: data)) ?? [:]
        return entries.compactMapValues(\.value)
    }

    private struct Lenient: Decodable {
        let value: AgentPreferences?
        init(from decoder: any Decoder) throws {
            value = try? AgentPreferences(from: decoder)
        }
    }
}
