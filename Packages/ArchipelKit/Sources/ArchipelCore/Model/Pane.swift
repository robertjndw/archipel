import Foundation

public enum TabContent: Codable, Hashable, Sendable {
    case session(Session.ID)
    case file(URL)
    /// `path` is relative to the worktree root.
    case diff(path: String, staged: Bool)
}

public struct Tab: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var content: TabContent
    /// A preview tab is reused by the next preview open, like a single-clicked file in VS Code. Session tabs are never previews.
    public var isPreview: Bool

    public init(id: UUID = UUID(), content: TabContent, isPreview: Bool = false) {
        self.id = id
        self.content = content
        self.isPreview = isPreview
    }
}

public struct Pane: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var tabs: [Tab]
    public var selectedTabID: Tab.ID?

    public init(id: UUID = UUID(), tabs: [Tab] = [], selectedTabID: Tab.ID? = nil) {
        self.id = id
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }

    /// The stored selection if it exists, otherwise the first tab.
    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID } ?? tabs.first
    }
}
